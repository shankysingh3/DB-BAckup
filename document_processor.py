#!/usr/bin/env python3
"""
Document Processor Service - Automated LLM Extraction for Carbon Accounting
============================================================================

This service polls the document_processing_queue table, extracts data from
uploaded documents using Groq's Llama 3.2 Vision LLM, and automatically
inserts emission records into the database.

Architecture:
  1. Poll document_processing_queue every N seconds (from .env)
  2. Pick up next queued document (with row-level locking)
  3. Convert PDF/image to base64 for Groq API
  4. Extract structured data using LLM with scope-specific prompts
  5. Validate extracted data (confidence score, required fields)
  6. Match emission factor from database
  7. Call insert_scope1_emission() or insert_scope2_emission()
  8. Link emission record back to document
  9. Update status to 'completed' or 'failed'

Usage:
  python document_processor.py

Requirements:
  - PostgreSQL with document_uploads and document_processing_queue tables
  - Groq API key in .env file
  - Poppler installed for PDF processing
  - Python dependencies from requirements.txt

Author: Carbon Accounting System
Date: 2025-11-03
Version: 1.0
"""

import os
import sys
import time
import json
import base64
import logging
import signal
from datetime import datetime, timedelta
from typing import Optional, Dict, Any, Tuple
from pathlib import Path
import random

# Third-party imports
try:
    import psycopg2
    from psycopg2 import pool
    from psycopg2.extras import RealDictCursor, Json
    from groq import Groq
    from pdf2image import convert_from_path
    from PIL import Image
    from dotenv import load_dotenv
except ImportError as e:
    print(f"ERROR: Missing required dependency: {e}")
    print("Please run: pip install -r requirements.txt")
    sys.exit(1)

# Load environment variables
load_dotenv()

# ============================================
# Configuration
# ============================================

DATABASE_CONFIG = {
    'host': os.getenv('DB_HOST', 'localhost'),
    'port': int(os.getenv('DB_PORT', 5432)),
    'database': os.getenv('DB_NAME', 'carbon_accounting'),
    'user': os.getenv('DB_USER', 'postgres'),
    'password': os.getenv('DB_PASSWORD', ''),
}

GROQ_API_KEY = os.getenv('GROQ_API_KEY')
if not GROQ_API_KEY:
    logging.error("GROQ_API_KEY environment variable not set!")
    sys.exit(1)

POLL_INTERVAL_SECONDS = int(os.getenv('POLL_INTERVAL_SECONDS', 10))
MAX_PROCESSING_TIME_MINUTES = int(os.getenv('MAX_PROCESSING_TIME_MINUTES', 5))
WORKER_ID = os.getenv('WORKER_ID', f"worker_{random.randint(10000, 99999)}")

# Groq model configuration
GROQ_MODEL = os.getenv('GROQ_MODEL', 'llama-3.2-11b-vision-preview')
GROQ_TEMPERATURE = float(os.getenv('GROQ_TEMPERATURE', 0.1))
GROQ_MAX_TOKENS = int(os.getenv('GROQ_MAX_TOKENS', 2048))

# Logging configuration
LOG_LEVEL = os.getenv('LOG_LEVEL', 'INFO')
LOG_FILE = 'document_processor.log'

# ============================================
# Logging Setup
# ============================================

logging.basicConfig(
    level=getattr(logging, LOG_LEVEL),
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler(LOG_FILE),
        logging.StreamHandler(sys.stdout)
    ]
)
logger = logging.getLogger(__name__)

# ============================================
# Global Variables
# ============================================

db_pool = None
groq_client = None
llm_prompts = None
shutdown_requested = False

# ============================================
# Signal Handlers
# ============================================

def signal_handler(signum, frame):
    """Handle shutdown signals gracefully"""
    global shutdown_requested
    logger.info(f"Received shutdown signal ({signum}), finishing current task...")
    shutdown_requested = True

signal.signal(signal.SIGINT, signal_handler)
signal.signal(signal.SIGTERM, signal_handler)

# ============================================
# Database Functions
# ============================================

def get_db_connection():
    """Get database connection from pool"""
    global db_pool
    if db_pool is None:
        db_pool = psycopg2.pool.SimpleConnectionPool(
            1, 10,
            **DATABASE_CONFIG
        )
    return db_pool.getconn()

def return_db_connection(conn):
    """Return connection to pool"""
    global db_pool
    if db_pool:
        db_pool.putconn(conn)

def get_next_queued_document(conn) -> Optional[Dict[str, Any]]:
    """
    Get next document from queue with row-level locking
    Uses FOR UPDATE SKIP LOCKED for multi-worker support
    """
    try:
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            cur.execute("""
                UPDATE document_processing_queue
                SET
                    status = 'processing',
                    worker_id = %s,
                    started_at = NOW(),
                    updated_at = NOW()
                WHERE id = (
                    SELECT id
                    FROM document_processing_queue
                    WHERE status = 'queued'
                    ORDER BY priority ASC, created_at ASC
                    LIMIT 1
                    FOR UPDATE SKIP LOCKED
                )
                RETURNING
                    id as queue_id,
                    document_upload_id,
                    priority,
                    retry_count
            """, (WORKER_ID,))

            queue_record = cur.fetchone()
            if not queue_record:
                return None

            # Get document details
            cur.execute("""
                SELECT
                    du.id,
                    du.organization_id,
                    du.site_id,
                    du.scope,
                    du.upload_type,
                    du.file_name,
                    du.file_path,
                    du.file_type,
                    du.uploaded_by
                FROM document_uploads du
                WHERE du.id = %s
            """, (queue_record['document_upload_id'],))

            doc_record = cur.fetchone()
            if not doc_record:
                logger.error(f"Document {queue_record['document_upload_id']} not found!")
                return None

            conn.commit()

            # Merge queue and document data
            result = dict(doc_record)
            result['queue_id'] = queue_record['queue_id']
            result['priority'] = queue_record['priority']
            result['retry_count'] = queue_record['retry_count']

            return result

    except Exception as e:
        conn.rollback()
        logger.error(f"Error getting next document: {e}")
        return None

def mark_processing_complete(conn, queue_id: str, document_id: str,
                            extracted_data: Dict, confidence_score: float,
                            emission_id: Optional[str], processing_time_ms: int):
    """Mark document processing as completed"""
    try:
        with conn.cursor() as cur:
            # Update queue
            cur.execute("""
                UPDATE document_processing_queue
                SET
                    status = 'completed',
                    completed_at = NOW(),
                    updated_at = NOW(),
                    llm_provider = 'groq',
                    llm_model = %s,
                    processing_time_ms = %s
                WHERE id = %s
            """, (GROQ_MODEL, processing_time_ms, queue_id))

            # Update document
            cur.execute("""
                UPDATE document_uploads
                SET
                    processing_status = 'processed',
                    extraction_status = 'completed',
                    extracted_data = %s,
                    extraction_confidence_score = %s,
                    linked_emission_entry_id = %s,
                    updated_at = NOW()
                WHERE id = %s
            """, (Json(extracted_data), confidence_score, emission_id, document_id))

            conn.commit()
            logger.info(f"Marked document {document_id} as completed (confidence: {confidence_score:.2f})")

    except Exception as e:
        conn.rollback()
        logger.error(f"Error marking document as complete: {e}")
        raise

def mark_processing_failed(conn, queue_id: str, document_id: str,
                          error_message: str, retry_count: int, max_retries: int):
    """Mark document processing as failed"""
    try:
        with conn.cursor() as cur:
            # Determine if we should retry
            should_retry = retry_count < max_retries
            queue_status = 'retrying' if should_retry else 'failed'
            doc_status = 'retrying' if should_retry else 'failed'

            # Update queue
            cur.execute("""
                UPDATE document_processing_queue
                SET
                    status = %s,
                    completed_at = NOW(),
                    updated_at = NOW(),
                    error_message = %s
                WHERE id = %s
            """, (queue_status, error_message, queue_id))

            # Update document
            cur.execute("""
                UPDATE document_uploads
                SET
                    extraction_status = %s,
                    extraction_errors = %s,
                    updated_at = NOW()
                WHERE id = %s
            """, (doc_status, error_message, document_id))

            conn.commit()

            if should_retry:
                logger.warning(f"Document {document_id} failed, will retry (attempt {retry_count + 1}/{max_retries})")
            else:
                logger.error(f"Document {document_id} failed permanently: {error_message}")

    except Exception as e:
        conn.rollback()
        logger.error(f"Error marking document as failed: {e}")

# ============================================
# LLM Functions
# ============================================

def load_llm_prompts() -> Dict:
    """Load LLM prompts from JSON file"""
    prompts_file = Path(__file__).parent / 'llm_prompts.json'
    try:
        with open(prompts_file, 'r', encoding='utf-8') as f:
            return json.load(f)
    except FileNotFoundError:
        logger.error(f"Prompts file not found: {prompts_file}")
        sys.exit(1)
    except json.JSONDecodeError as e:
        logger.error(f"Invalid JSON in prompts file: {e}")
        sys.exit(1)

def get_prompt_key(scope: int, upload_type: str) -> Optional[str]:
    """Map scope and upload_type to prompt key"""
    scope_type_map = {
        # Scope 1
        (1, 'fuel_receipt'): 'scope1_fuel',
        (1, 'fuel_invoice'): 'scope1_fuel',
        (1, 'delivery_note'): 'scope1_fuel',
        (1, 'waste_invoice'): 'scope1_waste',
        (1, 'waste_manifest'): 'scope1_waste',

        # Scope 2
        (2, 'utility_bill'): 'scope2_electricity',
        (2, 'electricity_bill'): 'scope2_electricity',
        (2, 'heat_bill'): 'scope2_heat_steam',
        (2, 'steam_bill'): 'scope2_heat_steam',
        (2, 'cooling_bill'): 'scope2_heat_steam',

        # Scope 3
        (3, 'freight_invoice'): 'scope3_logistics',
        (3, 'delivery_note'): 'scope3_logistics',
        (3, 'shipping_manifest'): 'scope3_logistics',
    }

    return scope_type_map.get((scope, upload_type))

def encode_image_to_base64(file_path: str, file_type: str) -> Optional[str]:
    """
    Convert PDF or image to base64 string for Groq API
    PDFs are converted to images using pdf2image (requires Poppler)
    """
    try:
        if file_type.lower() == 'pdf':
            # Convert PDF to images using Poppler
            logger.debug(f"Converting PDF to images: {file_path}")
            images = convert_from_path(file_path, dpi=300, first_page=1, last_page=1)

            if not images:
                raise ValueError("Unable to get page count.")

            # Use first page
            image = images[0]
        else:
            # Load image directly
            image = Image.open(file_path)

        # Convert to RGB if needed
        if image.mode != 'RGB':
            image = image.convert('RGB')

        # Resize if too large (max 2048x2048 for most APIs)
        max_size = 2048
        if image.width > max_size or image.height > max_size:
            image.thumbnail((max_size, max_size), Image.Resampling.LANCZOS)

        # Save to bytes
        from io import BytesIO
        buffer = BytesIO()
        image.save(buffer, format='JPEG', quality=95)
        buffer.seek(0)

        # Encode to base64
        image_base64 = base64.b64encode(buffer.read()).decode('utf-8')

        logger.debug(f"Image encoded successfully ({len(image_base64)} chars)")
        return image_base64

    except Exception as e:
        logger.error(f"Error encoding image {file_path}: {e}")
        raise

def extract_data_with_groq(image_base64: str, prompt_key: str) -> Dict[str, Any]:
    """
    Call Groq API with vision model to extract data from document
    """
    global groq_client, llm_prompts

    if groq_client is None:
        groq_client = Groq(api_key=GROQ_API_KEY)

    if llm_prompts is None:
        llm_prompts = load_llm_prompts()

    prompt_config = llm_prompts['prompts'].get(prompt_key)
    if not prompt_config:
        raise ValueError(f"Prompt key '{prompt_key}' not found in llm_prompts.json")

    system_prompt = prompt_config['system_prompt']
    user_prompt = prompt_config['user_prompt']

    try:
        logger.debug(f"Calling Groq API with model {GROQ_MODEL}")

        response = groq_client.chat.completions.create(
            model=GROQ_MODEL,
            messages=[
                {
                    "role": "system",
                    "content": system_prompt
                },
                {
                    "role": "user",
                    "content": [
                        {
                            "type": "text",
                            "text": user_prompt
                        },
                        {
                            "type": "image_url",
                            "image_url": {
                                "url": f"data:image/jpeg;base64,{image_base64}"
                            }
                        }
                    ]
                }
            ],
            temperature=GROQ_TEMPERATURE,
            max_tokens=GROQ_MAX_TOKENS,
        )

        # Extract JSON from response
        content = response.choices[0].message.content.strip()

        # Try to parse JSON (handle potential markdown formatting)
        if content.startswith('```json'):
            content = content.split('```json')[1].split('```')[0].strip()
        elif content.startswith('```'):
            content = content.split('```')[1].split('```')[0].strip()

        extracted_data = json.loads(content)

        logger.debug(f"Groq API response parsed successfully")
        return extracted_data

    except json.JSONDecodeError as e:
        logger.error(f"Failed to parse JSON from Groq response: {e}")
        logger.error(f"Raw response: {content if 'content' in locals() else 'N/A'}")
        raise ValueError(f"LLM extraction error: Invalid JSON response")
    except Exception as e:
        logger.error(f"Groq API error: {e}")
        raise ValueError(f"LLM extraction error: {str(e)}")

# ============================================
# Validation Functions
# ============================================

def validate_extracted_data(data: Dict, prompt_key: str) -> Tuple[bool, Optional[str]]:
    """
    Validate extracted data against rules in llm_prompts.json
    Returns (is_valid, error_message)
    """
    global llm_prompts

    prompt_config = llm_prompts['prompts'][prompt_key]
    validation_rules = llm_prompts['validation_rules']

    # Check confidence score
    confidence = data.get('confidence_score', 0.0)
    min_confidence = prompt_config.get('confidence_threshold', validation_rules['min_confidence_score'])

    if confidence < min_confidence:
        return False, f"Confidence score {confidence:.2f} below threshold {min_confidence}"

    # Check required fields
    if validation_rules.get('required_field_check', True):
        required_fields = prompt_config.get('required_fields', [])
        missing_fields = [f for f in required_fields if not data.get(f)]

        if missing_fields:
            return False, f"Missing required fields: {', '.join(missing_fields)}"

    # Check date ranges (if date fields present)
    date_fields = [k for k in data.keys() if 'date' in k.lower() and data[k]]
    for field in date_fields:
        try:
            date_val = datetime.strptime(data[field], '%Y-%m-%d')

            # Check not too far in past
            max_past = datetime.now() - timedelta(days=365 * validation_rules['max_date_past_years'])
            if date_val < max_past:
                return False, f"Date {field} too far in past: {data[field]}"

            # Check not too far in future
            max_future = datetime.now() + timedelta(days=validation_rules['max_date_future_days'])
            if date_val > max_future:
                return False, f"Date {field} too far in future: {data[field]}"

        except (ValueError, TypeError):
            return False, f"Invalid date format in {field}: {data[field]}"

    return True, None

# ============================================
# Emission Factor Matching
# ============================================

def match_emission_factor_scope1(conn, fuel_type: str) -> Optional[str]:
    """
    Match emission factor for Scope 1 fuel combustion
    Returns emission_factor_id or None
    """
    try:
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            # Try exact match first
            cur.execute("""
                SELECT ef.id
                FROM emission_factors ef
                JOIN emission_factor_classifications efc ON ef.id = efc.emission_factor_id
                WHERE ef.scope = 1
                  AND ef.is_active = true
                  AND LOWER(ef.fuel_type) = LOWER(%s)
                LIMIT 1
            """, (fuel_type,))

            result = cur.fetchone()
            if result:
                return result['id']

            # Try fuzzy match
            cur.execute("""
                SELECT ef.id
                FROM emission_factors ef
                JOIN emission_factor_classifications efc ON ef.id = efc.emission_factor_id
                WHERE ef.scope = 1
                  AND ef.is_active = true
                  AND LOWER(ef.fuel_type) LIKE LOWER(%s)
                LIMIT 1
            """, (f'%{fuel_type}%',))

            result = cur.fetchone()
            return result['id'] if result else None

    except Exception as e:
        logger.error(f"Error matching Scope 1 emission factor: {e}")
        return None

def match_emission_factor_scope2(conn, site_id: str, energy_type: str) -> Optional[str]:
    """
    Match emission factor for Scope 2 electricity/heat/steam
    For electricity, uses grid region from site
    Returns emission_factor_id or None
    """
    try:
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            if energy_type.lower() in ['electricity', 'electric']:
                # Get site's grid region
                cur.execute("""
                    SELECT grid_region_code
                    FROM sites
                    WHERE id = %s
                """, (site_id,))

                site = cur.fetchone()
                if not site or not site['grid_region_code']:
                    logger.warning(f"Site {site_id} has no grid region code")
                    return None

                # Match emission factor by grid region
                cur.execute("""
                    SELECT ef.id
                    FROM emission_factors ef
                    WHERE ef.scope = 2
                      AND ef.is_active = true
                      AND ef.grid_region_code = %s
                      AND LOWER(ef.energy_type) = 'electricity'
                    ORDER BY ef.year DESC
                    LIMIT 1
                """, (site['grid_region_code'],))

            else:
                # Heat/Steam/Cooling - match by energy type
                cur.execute("""
                    SELECT ef.id
                    FROM emission_factors ef
                    WHERE ef.scope = 2
                      AND ef.is_active = true
                      AND LOWER(ef.energy_type) = LOWER(%s)
                    ORDER BY ef.year DESC
                    LIMIT 1
                """, (energy_type,))

            result = cur.fetchone()
            return result['id'] if result else None

    except Exception as e:
        logger.error(f"Error matching Scope 2 emission factor: {e}")
        return None

# ============================================
# Emission Insertion Functions
# ============================================

def insert_scope1_emission(conn, document: Dict, extracted_data: Dict,
                          emission_factor_id: str) -> Optional[str]:
    """
    Call insert_scope1_emission() PostgreSQL function
    Returns emission_id or None
    """
    try:
        # Extract year and month from date
        date_field = extracted_data.get('invoice_date') or extracted_data.get('billing_period_start')
        if not date_field:
            raise ValueError("No date field found in extracted data")

        date_obj = datetime.strptime(date_field, '%Y-%m-%d')
        year = date_obj.year
        month = date_obj.month

        # Get consumption details
        consumption = extracted_data.get('consumption_amount') or extracted_data.get('weight_volume')
        if not consumption:
            raise ValueError("No consumption amount found")

        combustion_type = extracted_data.get('combustion_type')
        equipment = extracted_data.get('equipment_vehicle_details')
        notes = extracted_data.get('extraction_notes', '')

        with conn.cursor() as cur:
            cur.execute("""
                SELECT insert_scope1_emission(
                    %s, %s, %s, %s, %s, %s, %s, %s, %s, %s
                )
            """, (
                document['site_id'],
                year,
                month,
                emission_factor_id,
                consumption,
                document['uploaded_by'],
                combustion_type,
                equipment,
                notes,
                document['id']  # document_upload_id
            ))

            emission_id = cur.fetchone()[0]
            conn.commit()

            logger.info(f"Inserted Scope 1 emission: {emission_id}")
            return emission_id

    except Exception as e:
        conn.rollback()
        logger.error(f"Error inserting Scope 1 emission: {e}")
        raise

def insert_scope2_emission(conn, document: Dict, extracted_data: Dict,
                          emission_factor_id: Optional[str]) -> Optional[str]:
    """
    Call insert_scope2_emission() PostgreSQL function
    Returns emission_id or None
    """
    try:
        # Extract year and month from billing period
        start_date = extracted_data.get('billing_period_start')
        if not start_date:
            raise ValueError("No billing_period_start found")

        date_obj = datetime.strptime(start_date, '%Y-%m-%d')
        year = date_obj.year
        month = date_obj.month

        # Determine energy type
        if 'service_type' in extracted_data:
            # Heat/Steam/Cooling
            energy_type = extracted_data['service_type']
            consumption = extracted_data.get('consumption_amount')
        else:
            # Electricity
            energy_type = 'Electricity'
            consumption = extracted_data.get('total_consumption_kwh')

        if not consumption:
            raise ValueError("No consumption amount found")

        notes = extracted_data.get('extraction_notes', '')

        with conn.cursor() as cur:
            cur.execute("""
                SELECT insert_scope2_emission(
                    %s, %s, %s, %s, %s, %s, %s, %s, %s
                )
            """, (
                document['site_id'],
                year,
                month,
                energy_type,
                consumption,
                document['uploaded_by'],
                emission_factor_id,
                notes,
                document['id']  # document_upload_id
            ))

            emission_id = cur.fetchone()[0]
            conn.commit()

            logger.info(f"Inserted Scope 2 emission: {emission_id}")
            return emission_id

    except Exception as e:
        conn.rollback()
        logger.error(f"Error inserting Scope 2 emission: {e}")
        raise

# ============================================
# Main Processing Function
# ============================================

def process_document(document: Dict) -> bool:
    """
    Process a single document end-to-end
    Returns True if successful, False otherwise
    """
    conn = None
    start_time = time.time()

    try:
        conn = get_db_connection()

        logger.info(f"Processing document {document['id']} (scope {document['scope']})")

        # Step 1: Get prompt key
        prompt_key = get_prompt_key(document['scope'], document['upload_type'])
        if not prompt_key:
            raise ValueError(f"No prompt found for scope {document['scope']}, type {document['upload_type']}")

        logger.debug(f"Using prompt: {prompt_key}")

        # Step 2: Encode image
        image_base64 = encode_image_to_base64(document['file_path'], document['file_type'])

        # Step 3: Extract data with LLM
        extracted_data = extract_data_with_groq(image_base64, prompt_key)

        # Step 4: Validate extracted data
        is_valid, error_msg = validate_extracted_data(extracted_data, prompt_key)
        if not is_valid:
            raise ValueError(f"Validation failed: {error_msg}")

        confidence = extracted_data.get('confidence_score', 0.0)
        logger.info(f"Extracted data with confidence {confidence:.2f}")

        # Step 5: Match emission factor
        emission_factor_id = None
        if document['scope'] == 1:
            fuel_type = extracted_data.get('fuel_type') or extracted_data.get('waste_type')
            if fuel_type:
                emission_factor_id = match_emission_factor_scope1(conn, fuel_type)
        elif document['scope'] == 2:
            energy_type = extracted_data.get('service_type', 'Electricity')
            emission_factor_id = match_emission_factor_scope2(conn, document['site_id'], energy_type)

        if not emission_factor_id and document['scope'] in [1, 2]:
            logger.warning(f"No matching emission factor found, will still create record")

        # Step 6: Insert emission record
        emission_id = None
        if document['scope'] == 1:
            if emission_factor_id:
                emission_id = insert_scope1_emission(conn, document, extracted_data, emission_factor_id)
        elif document['scope'] == 2:
            emission_id = insert_scope2_emission(conn, document, extracted_data, emission_factor_id)
        elif document['scope'] == 3:
            logger.warning("Scope 3 insertion not yet implemented")

        # Step 7: Mark as complete
        processing_time_ms = int((time.time() - start_time) * 1000)
        mark_processing_complete(
            conn, document['queue_id'], document['id'],
            extracted_data, confidence, emission_id, processing_time_ms
        )

        logger.info(f"Successfully processed document {document['id']} in {processing_time_ms}ms")
        return True

    except Exception as e:
        logger.error(f"Error processing document {document['id']}: {e}")

        if conn:
            mark_processing_failed(
                conn, document['queue_id'], document['id'],
                str(e), document['retry_count'], 3  # max_retries = 3
            )

        return False

    finally:
        if conn:
            return_db_connection(conn)

# ============================================
# Main Loop
# ============================================

def main():
    """Main service loop"""
    logger.info(f"Document processor started (worker: {WORKER_ID})")
    logger.info(f"Polling interval: {POLL_INTERVAL_SECONDS} seconds")
    logger.info(f"Using Groq model: {GROQ_MODEL}")

    # Load prompts on startup
    global llm_prompts
    llm_prompts = load_llm_prompts()
    logger.info(f"Loaded {len(llm_prompts['prompts'])} prompt templates")

    while not shutdown_requested:
        conn = None
        try:
            conn = get_db_connection()

            # Get next document
            document = get_next_queued_document(conn)

            if document:
                logger.info(f"Picked up document {document['id']} (queue {document['queue_id']})")

                # Process document
                success = process_document(document)

                if not success:
                    logger.warning(f"Document {document['id']} processing failed")

            else:
                # No documents, wait before polling again
                logger.debug("No documents in queue, waiting...")
                time.sleep(POLL_INTERVAL_SECONDS)

        except KeyboardInterrupt:
            logger.info("Keyboard interrupt received")
            break

        except Exception as e:
            logger.error(f"Unexpected error in main loop: {e}", exc_info=True)
            time.sleep(POLL_INTERVAL_SECONDS)

        finally:
            if conn:
                return_db_connection(conn)

    logger.info("Document processor stopped")

# ============================================
# Entry Point
# ============================================

if __name__ == '__main__':
    try:
        main()
    except Exception as e:
        logger.critical(f"Fatal error: {e}", exc_info=True)
        sys.exit(1)
