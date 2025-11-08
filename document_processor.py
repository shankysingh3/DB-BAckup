#!/usr/bin/env python3
"""
Document Processing Service - LLM-Powered Carbon Accounting
============================================================

Automatically extracts emissions data from uploaded documents using Groq's
Llama 3.2 11B Vision model and inserts into carbon accounting database.

Requirements:
    - PostgreSQL database with document_uploads and document_processing_queue tables
    - Groq API key (free tier: 14,400 requests/day)
    - Poppler installed (for PDF processing)
    - Python 3.9+

Usage:
    python document_processor.py

Environment Variables (.env file):
    GROQ_API_KEY=gsk_...
    DB_HOST=localhost
    DB_PORT=5432
    DB_NAME=carbon_accounting
    DB_USER=postgres
    DB_PASSWORD=your_password

Author: Carbon Accounting System
Version: 1.0
"""

import os
import sys
import time
import json
import base64
import logging
import psycopg2
from psycopg2.extras import RealDictCursor
from datetime import datetime, date
from typing import Optional, Dict, Any, Tuple
from pathlib import Path

# Third-party imports
try:
    from groq import Groq
    from pdf2image import convert_from_path
    from PIL import Image
    from dotenv import load_dotenv
except ImportError as e:
    print(f"❌ Missing dependency: {e}")
    print("\n📦 Install dependencies:")
    print("pip install groq psycopg2-binary pdf2image pillow python-dotenv")
    sys.exit(1)

# Load environment variables
load_dotenv()

# Configuration
GROQ_API_KEY = os.getenv('GROQ_API_KEY')
DB_CONFIG = {
    'host': os.getenv('DB_HOST', 'localhost'),
    'port': int(os.getenv('DB_PORT', 5432)),
    'database': os.getenv('DB_NAME', 'carbon_accounting'),
    'user': os.getenv('DB_USER', 'postgres'),
    'password': os.getenv('DB_PASSWORD', ''),
}
POLL_INTERVAL_SECONDS = int(os.getenv('POLL_INTERVAL_SECONDS', 10))
WORKER_ID = os.getenv('WORKER_ID', f'worker_{os.getpid()}')

# Logging setup
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('document_processor.log'),
        logging.StreamHandler(sys.stdout)
    ]
)
logger = logging.getLogger(__name__)


# ============================================================================
# Validation
# ============================================================================

def validate_config():
    """Validate required configuration."""
    if not GROQ_API_KEY:
        logger.error("❌ GROQ_API_KEY not found in environment variables")
        logger.error("Create a .env file with: GROQ_API_KEY=gsk_...")
        sys.exit(1)

    if not DB_CONFIG['password']:
        logger.warning("⚠️ DB_PASSWORD is empty - this may cause connection issues")

    logger.info(f"✅ Configuration loaded")
    logger.info(f"   Worker ID: {WORKER_ID}")
    logger.info(f"   Database: {DB_CONFIG['database']}@{DB_CONFIG['host']}")
    logger.info(f"   Poll interval: {POLL_INTERVAL_SECONDS}s")


# ============================================================================
# Database Operations
# ============================================================================

def get_db_connection():
    """Get PostgreSQL database connection."""
    try:
        conn = psycopg2.connect(**DB_CONFIG)
        return conn
    except psycopg2.Error as e:
        logger.error(f"❌ Database connection failed: {e}")
        raise


def get_next_queued_document(conn) -> Optional[Dict[str, Any]]:
    """
    Get next queued document using row-level locking (multi-worker safe).

    Returns:
        Dict with document details or None if queue is empty
    """
    try:
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            # Use SKIP LOCKED to prevent race conditions
            cur.execute("""
                UPDATE document_processing_queue
                SET status = 'processing',
                    worker_id = %s,
                    started_at = NOW(),
                    updated_at = NOW()
                WHERE id = (
                    SELECT id
                    FROM document_processing_queue
                    WHERE status = 'queued'
                    ORDER BY priority ASC, created_at ASC
                    FOR UPDATE SKIP LOCKED
                    LIMIT 1
                )
                RETURNING
                    id AS queue_id,
                    document_upload_id,
                    priority,
                    retry_count,
                    max_retries
            """, (WORKER_ID,))

            queue_record = cur.fetchone()

            if not queue_record:
                return None

            # Get document details
            cur.execute("""
                SELECT
                    id,
                    organization_id,
                    site_id,
                    scope,
                    upload_type,
                    file_name,
                    file_path,
                    file_type,
                    uploaded_by
                FROM document_uploads
                WHERE id = %s
            """, (queue_record['document_upload_id'],))

            document = cur.fetchone()

            if not document:
                logger.error(f"❌ Document not found: {queue_record['document_upload_id']}")
                return None

            conn.commit()

            # Combine queue and document info
            return {**dict(queue_record), **dict(document)}

    except psycopg2.Error as e:
        conn.rollback()
        logger.error(f"❌ Error getting next document: {e}")
        return None


def mark_processing_complete(conn, queue_id: str, processing_time_ms: int,
                            llm_provider: str, llm_model: str):
    """Mark document processing as completed."""
    try:
        with conn.cursor() as cur:
            cur.execute("""
                UPDATE document_processing_queue
                SET status = 'completed',
                    completed_at = NOW(),
                    processing_time_ms = %s,
                    llm_provider = %s,
                    llm_model = %s,
                    updated_at = NOW()
                WHERE id = %s
            """, (processing_time_ms, llm_provider, llm_model, queue_id))
            conn.commit()
            logger.info(f"✅ Marked as completed: {queue_id}")
    except psycopg2.Error as e:
        conn.rollback()
        logger.error(f"❌ Error marking complete: {e}")


def mark_processing_failed(conn, queue_id: str, error_message: str):
    """Mark document processing as failed."""
    try:
        with conn.cursor() as cur:
            cur.execute("""
                UPDATE document_processing_queue
                SET status = 'failed',
                    completed_at = NOW(),
                    error_message = %s,
                    updated_at = NOW()
                WHERE id = %s
            """, (error_message, queue_id))
            conn.commit()
            logger.warning(f"⚠️ Marked as failed: {queue_id} - {error_message}")
    except psycopg2.Error as e:
        conn.rollback()
        logger.error(f"❌ Error marking failed: {e}")


# ============================================================================
# LLM Integration
# ============================================================================

def load_prompts() -> Dict[str, Any]:
    """Load LLM prompts from JSON file."""
    prompts_file = Path(__file__).parent / 'llm_prompts.json'

    if not prompts_file.exists():
        logger.error(f"❌ Prompts file not found: {prompts_file}")
        raise FileNotFoundError(f"llm_prompts.json not found in {prompts_file.parent}")

    with open(prompts_file, 'r') as f:
        return json.load(f)


def get_prompt_key(scope: int, upload_type: str) -> Optional[str]:
    """Map scope and upload type to prompt key."""
    scope_type_map = {
        (1, 'fuel_receipt'): 'scope1_fuel',
        (1, 'fuel_invoice'): 'scope1_fuel',
        (1, 'waste_receipt'): 'scope1_waste',
        (1, 'waste_invoice'): 'scope1_waste',
        (2, 'utility_bill'): 'scope2_electricity',
        (2, 'electricity_bill'): 'scope2_electricity',
        (2, 'heat_bill'): 'scope2_heat_steam',
        (2, 'steam_bill'): 'scope2_heat_steam',
        (2, 'cooling_bill'): 'scope2_heat_steam',
        (3, 'logistics_invoice'): 'scope3_logistics',
        (3, 'shipping_invoice'): 'scope3_logistics',
        (3, 'freight_bill'): 'scope3_logistics',
    }

    return scope_type_map.get((scope, upload_type))


def encode_image_to_base64(file_path: str) -> str:
    """
    Convert PDF/image to base64 for Groq API.

    Args:
        file_path: Path to PDF or image file

    Returns:
        Base64-encoded image string
    """
    file_path = Path(file_path)

    if not file_path.exists():
        raise FileNotFoundError(f"File not found: {file_path}")

    # Convert PDF to image if needed
    if file_path.suffix.lower() == '.pdf':
        logger.info(f"📄 Converting PDF to image: {file_path.name}")
        images = convert_from_path(str(file_path), dpi=150, first_page=1, last_page=1)
        image = images[0]
    else:
        logger.info(f"🖼️ Loading image: {file_path.name}")
        image = Image.open(file_path)

    # Convert to RGB if needed
    if image.mode != 'RGB':
        image = image.convert('RGB')

    # Save to bytes
    from io import BytesIO
    buffer = BytesIO()
    image.save(buffer, format='PNG')
    image_bytes = buffer.getvalue()

    # Encode to base64
    base64_image = base64.b64encode(image_bytes).decode('utf-8')

    logger.info(f"✅ Image encoded ({len(base64_image)} bytes)")
    return base64_image


def extract_data_with_groq(file_path: str, prompt_config: Dict[str, Any]) -> Dict[str, Any]:
    """
    Extract data from document using Groq API.

    Args:
        file_path: Path to document file
        prompt_config: Prompt configuration from llm_prompts.json

    Returns:
        Extracted data as dictionary
    """
    try:
        # Initialize Groq client
        client = Groq(api_key=GROQ_API_KEY)

        # Encode image
        base64_image = encode_image_to_base64(file_path)

        # Call Groq API
        logger.info(f"🤖 Calling Groq API with {prompt_config['name']}")

        response = client.chat.completions.create(
            model="llama-3.2-11b-vision-preview",
            messages=[
                {
                    "role": "system",
                    "content": prompt_config['system_prompt']
                },
                {
                    "role": "user",
                    "content": [
                        {
                            "type": "text",
                            "text": prompt_config['user_prompt']
                        },
                        {
                            "type": "image_url",
                            "image_url": {
                                "url": f"data:image/png;base64,{base64_image}"
                            }
                        }
                    ]
                }
            ],
            temperature=0.1,  # Low temperature for consistent extraction
            max_tokens=2000
        )

        # Parse response
        content = response.choices[0].message.content

        # Try to extract JSON from response
        # Sometimes LLM wraps JSON in markdown code blocks
        if '```json' in content:
            content = content.split('```json')[1].split('```')[0].strip()
        elif '```' in content:
            content = content.split('```')[1].split('```')[0].strip()

        data = json.loads(content)

        logger.info(f"✅ Extracted data with confidence: {data.get('confidence_score', 'N/A')}")

        return data

    except json.JSONDecodeError as e:
        logger.error(f"❌ Failed to parse JSON from LLM response: {e}")
        logger.error(f"Response content: {content[:500]}")
        raise
    except Exception as e:
        logger.error(f"❌ Groq API error: {e}")
        raise


# ============================================================================
# Emission Factor Matching & Insertion
# ============================================================================

def insert_scope2_emission(conn, document: Dict[str, Any], extracted_data: Dict[str, Any]) -> str:
    """
    Insert Scope 2 emission using database function.

    Returns:
        UUID of created emission record
    """
    try:
        with conn.cursor() as cur:
            # Determine energy type
            service_type = extracted_data.get('service_type', 'Electricity')

            # Extract consumption (convert to float)
            consumption_kwh = float(extracted_data.get('total_consumption_kwh',
                                    extracted_data.get('consumption_value', 0)))

            # Extract date and parse to year/month
            bill_date_str = extracted_data.get('bill_date',
                            extracted_data.get('billing_period_end', str(date.today())))
            bill_date = datetime.strptime(bill_date_str, '%Y-%m-%d').date()

            # Call insert_scope2_emission function
            cur.execute("""
                SELECT insert_scope2_emission(
                    %s,  -- p_site_id
                    %s,  -- p_year
                    %s,  -- p_month
                    %s,  -- p_energy_type
                    %s,  -- p_consumption_value
                    %s,  -- p_uploaded_by
                    NULL,  -- p_emission_factor_id (auto-select)
                    %s,  -- p_notes
                    %s   -- p_document_upload_id
                )
            """, (
                document['site_id'],
                bill_date.year,
                bill_date.month,
                service_type,
                consumption_kwh,
                document['uploaded_by'],
                f"Auto-extracted from {document['file_name']}",
                document['id']
            ))

            emission_id = cur.fetchone()[0]
            conn.commit()

            logger.info(f"✅ Created Scope 2 emission: {emission_id}")
            return emission_id

    except psycopg2.Error as e:
        conn.rollback()
        logger.error(f"❌ Failed to insert Scope 2 emission: {e}")
        raise


def insert_scope1_emission(conn, document: Dict[str, Any], extracted_data: Dict[str, Any]) -> str:
    """Insert Scope 1 emission using database function."""
    # Implementation similar to Scope 2
    # Left as exercise - depends on your insert_scope1_emission function signature
    raise NotImplementedError("Scope 1 insertion not yet implemented")


def link_emission_to_document(conn, document_id: str, emission_id: str,
                              scope: int, extracted_data: Dict[str, Any],
                              confidence_score: float):
    """Link created emission back to document."""
    try:
        with conn.cursor() as cur:
            cur.execute("""
                SELECT link_emission_to_document(%s, %s, %s, %s, %s)
            """, (
                document_id,
                emission_id,
                scope,
                json.dumps(extracted_data),
                confidence_score
            ))
            conn.commit()
            logger.info(f"✅ Linked emission {emission_id} to document {document_id}")
    except psycopg2.Error as e:
        conn.rollback()
        logger.error(f"❌ Failed to link emission: {e}")


# ============================================================================
# Main Processing Logic
# ============================================================================

def process_document(conn, document: Dict[str, Any]) -> bool:
    """
    Process a single document end-to-end.

    Args:
        conn: Database connection
        document: Document record with queue info

    Returns:
        True if successful, False otherwise
    """
    start_time = time.time()

    logger.info(f"📄 Processing: {document['file_name']} (Scope {document['scope']})")

    try:
        # Load prompts
        prompts = load_prompts()

        # Get prompt for this document type
        prompt_key = get_prompt_key(document['scope'], document['upload_type'])

        if not prompt_key:
            raise ValueError(f"No prompt found for scope={document['scope']}, type={document['upload_type']}")

        if prompt_key not in prompts['prompts']:
            raise ValueError(f"Prompt key '{prompt_key}' not found in llm_prompts.json")

        prompt_config = prompts['prompts'][prompt_key]

        # Extract data using LLM
        extracted_data = extract_data_with_groq(document['file_path'], prompt_config)

        # Validate confidence score
        confidence_score = extracted_data.get('confidence_score', 0)
        min_confidence = prompts['validation_rules'].get('min_confidence_score', 0.6)

        if confidence_score < min_confidence:
            logger.warning(f"⚠️ Low confidence ({confidence_score:.2f} < {min_confidence})")
            logger.warning(f"   Notes: {extracted_data.get('extraction_notes', 'N/A')}")

        # Insert emission based on scope
        if document['scope'] == 2:
            emission_id = insert_scope2_emission(conn, document, extracted_data)
        elif document['scope'] == 1:
            emission_id = insert_scope1_emission(conn, document, extracted_data)
        else:
            raise NotImplementedError(f"Scope {document['scope']} not yet implemented")

        # Link emission to document
        link_emission_to_document(
            conn,
            document['id'],
            emission_id,
            document['scope'],
            extracted_data,
            confidence_score
        )

        # Mark as complete
        processing_time_ms = int((time.time() - start_time) * 1000)
        mark_processing_complete(
            conn,
            document['queue_id'],
            processing_time_ms,
            'groq',
            'llama-3.2-11b-vision-preview'
        )

        logger.info(f"✅ Completed in {processing_time_ms}ms")
        return True

    except Exception as e:
        logger.error(f"❌ Processing failed: {e}", exc_info=True)
        mark_processing_failed(conn, document['queue_id'], str(e))
        return False


# ============================================================================
# Main Loop
# ============================================================================

def main():
    """Main processing loop."""
    logger.info("="* 60)
    logger.info("🚀 Document Processor Starting")
    logger.info("="*60)

    # Validate configuration
    validate_config()

    # Test database connection
    try:
        conn = get_db_connection()
        logger.info("✅ Database connection successful")
        conn.close()
    except Exception as e:
        logger.error(f"❌ Cannot connect to database: {e}")
        sys.exit(1)

    logger.info(f"👁️ Polling queue every {POLL_INTERVAL_SECONDS} seconds...")
    logger.info("Press Ctrl+C to stop")
    logger.info("")

    processed_count = 0

    try:
        while True:
            conn = get_db_connection()

            try:
                # Get next document
                document = get_next_queued_document(conn)

                if document:
                    # Process it
                    success = process_document(conn, document)

                    if success:
                        processed_count += 1

                    logger.info(f"📊 Total processed this session: {processed_count}")
                    logger.info("")
                else:
                    # Queue is empty
                    logger.debug(f"💤 No documents in queue, waiting {POLL_INTERVAL_SECONDS}s...")
                    time.sleep(POLL_INTERVAL_SECONDS)

            except KeyboardInterrupt:
                raise  # Re-raise to outer handler
            except Exception as e:
                logger.error(f"❌ Unexpected error: {e}", exc_info=True)
                time.sleep(POLL_INTERVAL_SECONDS)
            finally:
                conn.close()

    except KeyboardInterrupt:
        logger.info("")
        logger.info("🛑 Shutting down gracefully...")
        logger.info(f"📊 Total documents processed: {processed_count}")
        logger.info("👋 Goodbye!")
        sys.exit(0)


if __name__ == '__main__':
    main()
