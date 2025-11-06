# LLM-Powered Document Processing - Setup Guide

## Overview

This system automatically extracts emissions data from uploaded documents (PDFs, images) using Groq's Llama 3.2 11B Vision model and inserts the data into your carbon accounting database.

## Architecture

```
User Upload → SharePoint Storage → document_uploads table
                                           ↓
                                    [PostgreSQL Trigger]
                                           ↓
                              document_processing_queue
                                           ↓
                                  [Python Service Polls]
                                           ↓
                                  Groq API (Llama 3.2 11B)
                                           ↓
                                  Extracted JSON Data
                                           ↓
                          [Match Emission Factor + Validate]
                                           ↓
                    insert_scope1/2/3_emission() function
                                           ↓
                              emissions_scope_1/2/3 table
                                           ↓
                          Link back to document_uploads
```

## Prerequisites

### 1. Database Requirements
- PostgreSQL 13+ with existing carbon accounting schema
- Tables: `document_uploads`, `document_processing_queue`, `emission_factors`, etc.
- Scope 1 and Scope 2 emission functions already created

### 2. Groq API Account (FREE)
1. Go to https://console.groq.com/
2. Sign up for free account
3. Generate API key (14,400 requests/day free tier)
4. Model: `llama-3.2-11b-vision-preview` (supports images + PDFs)

**Alternative Options:**
- **HuggingFace Inference API**: Free but rate-limited
- **Ollama (Local)**: Requires GPU (8GB+ VRAM for Llama 3.2 11B)
- **Together AI**: Free credits, then paid

**Why Groq?**
- ✅ Fastest inference speed (~500 tokens/sec)
- ✅ Free tier: 14,400 requests/day
- ✅ Vision support (PDFs, images)
- ✅ No infrastructure needed
- ✅ Production-ready uptime

### 3. Python Environment
- Python 3.9+
- pip package manager
- Windows/Linux/macOS compatible

### 4. SharePoint Integration (Optional)
- Document storage in SharePoint or local file system
- `file_path` in `document_uploads` must point to accessible location

---

## Installation Steps

### Step 1: Install PostgreSQL Triggers

```bash
# Run the trigger creation script
psql -U postgres -d carbon_accounting -f create_document_processing_triggers.sql
```

**What this does:**
- Creates `auto_queue_document_for_processing()` trigger function
- Automatically adds documents to queue when uploaded
- Creates helper functions: `link_emission_to_document()`, `retry_failed_document()`, etc.

**Verify installation:**
```sql
SELECT * FROM information_schema.triggers WHERE trigger_name LIKE '%document%';
```

Expected output:
- `trigger_auto_queue_document` on `document_uploads`
- `trigger_update_document_status` on `document_processing_queue`

---

### Step 2: Set Up Python Environment

```bash
# Create virtual environment (recommended)
python -m venv document_processor_env

# Activate virtual environment
# Windows:
document_processor_env\Scripts\activate
# Linux/Mac:
source document_processor_env/bin/activate

# Install dependencies
pip install -r requirements.txt
```

**Dependencies installed:**
- `groq` - Groq API client
- `psycopg2-binary` - PostgreSQL adapter
- `pdf2image` - PDF to image converter (requires poppler)
- `Pillow` - Image processing
- `python-dotenv` - Environment variable management

**Additional requirement for PDF processing:**

**Windows:**
1. Download poppler for Windows: https://github.com/oschwartz10612/poppler-windows/releases/
2. Extract to `C:\Program Files\poppler`
3. Add `C:\Program Files\poppler\Library\bin` to PATH

**Linux (Ubuntu/Debian):**
```bash
sudo apt-get install poppler-utils
```

**Mac:**
```bash
brew install poppler
```

---

### Step 3: Configure Environment Variables

Create a `.env` file in the same directory as `document_processor.py`:

```bash
# .env file
# =============================

# Groq API Configuration
GROQ_API_KEY=gsk_your_api_key_here

# Database Configuration
DB_HOST=localhost
DB_PORT=5432
DB_NAME=carbon_accounting
DB_USER=postgres
DB_PASSWORD=your_password_here

# Optional: Logging level
LOG_LEVEL=INFO

# Optional: Worker configuration
POLL_INTERVAL_SECONDS=10
MAX_PROCESSING_TIME_MINUTES=5
```

**Security Note:**
- Never commit `.env` file to version control
- Add `.env` to `.gitignore`
- Use environment-specific variables in production

---

### Step 4: Test Database Connection

```bash
# Test Python can connect to database
python -c "import psycopg2; import os; from dotenv import load_dotenv; load_dotenv(); conn = psycopg2.connect(host=os.getenv('DB_HOST'), database=os.getenv('DB_NAME'), user=os.getenv('DB_USER'), password=os.getenv('DB_PASSWORD')); print('Connection successful!'); conn.close()"
```

Expected output: `Connection successful!`

---

### Step 5: Test Groq API Connection

```bash
# Test Groq API key
python -c "from groq import Groq; import os; from dotenv import load_dotenv; load_dotenv(); client = Groq(api_key=os.getenv('GROQ_API_KEY')); print('Groq client initialized successfully!')"
```

Expected output: `Groq client initialized successfully!`

---

### Step 6: Run the Document Processor Service

```bash
# Start the service
python document_processor.py
```

**Expected console output:**
```
2025-11-03 10:00:00,123 - __main__ - INFO - Document processor started (worker: worker_12345)
2025-11-03 10:00:00,124 - __main__ - INFO - Polling interval: 10 seconds
2025-11-03 10:00:00,125 - __main__ - DEBUG - No documents in queue, waiting...
```

**Service behavior:**
- Polls `document_processing_queue` every 10 seconds
- When document found, processes it immediately
- Logs all activity to `document_processor.log` and console
- Runs indefinitely until stopped (Ctrl+C)

---

## Usage Workflow

### Uploading a Document

1. **User uploads document** via your application UI
2. **Document saved to SharePoint** (or local storage)
3. **Insert into `document_uploads` table:**

```sql
INSERT INTO document_uploads (
    organization_id,
    site_id,
    scope,
    upload_type,
    file_name,
    file_path,
    file_type,
    file_size_kb,
    uploaded_by
) VALUES (
    'org-uuid-here',
    'site-uuid-here',
    2,  -- Scope 2
    'utility_bill',  -- Type
    'electricity_bill_jan_2024.pdf',
    '/sharepoint/documents/electricity_bill_jan_2024.pdf',
    'pdf',
    250,
    'user-uuid-here'
) RETURNING id;
```

4. **Trigger automatically queues document** (no manual action needed)
5. **Python service picks up document** within 10 seconds
6. **LLM extracts data** from PDF/image
7. **Emission record created** in `emissions_scope_2` table
8. **Document linked** to emission record

### Checking Processing Status

```sql
-- Check document status
SELECT
    id,
    file_name,
    extraction_status,
    extraction_confidence_score,
    linked_emission_entry_id
FROM document_uploads
WHERE id = 'document-uuid-here';
```

**Possible statuses:**
- `queued` - Waiting for processing
- `processing` - Currently being processed by LLM
- `completed` - Successfully extracted and inserted
- `failed` - Extraction failed (check `extraction_errors`)
- `retrying` - Failed but retrying

### Viewing Extracted Data

```sql
SELECT
    id,
    file_name,
    extraction_confidence_score,
    extracted_data,
    linked_emission_entry_id
FROM document_uploads
WHERE extraction_status = 'completed'
ORDER BY uploaded_at DESC
LIMIT 10;
```

**Example `extracted_data` (JSONB):**
```json
{
  "supplier_name": "British Gas",
  "bill_date": "2024-01-15",
  "billing_period_start": "2023-12-01",
  "billing_period_end": "2023-12-31",
  "total_consumption_kwh": 1250.5,
  "consumption_unit": "kWh",
  "total_cost": 312.50,
  "currency": "GBP",
  "supply_address": "123 Main Street, London",
  "is_green_tariff": false,
  "confidence_score": 0.95,
  "extraction_notes": "All fields extracted successfully"
}
```

---

## Monitoring and Maintenance

### Real-Time Monitoring

```sql
-- Quick health check
SELECT * FROM get_queue_health();
```

**Output:**
```
metric                    | value
--------------------------+-------
queued_documents          | 5
processing_documents      | 1
failed_documents_24h      | 2
avg_processing_time_ms    | 3500
success_rate_24h_pct      | 96.50
```

### Dashboard Queries

Run monitoring queries from `monitor_document_processing.sql`:

```bash
psql -U postgres -d carbon_accounting -f monitor_document_processing.sql
```

**Key queries:**
1. **Queue Status Overview** - Current queue state
2. **Processing Performance by Scope** - Success rates per scope
3. **Failed Documents** - Troubleshooting errors
4. **Extraction Confidence Analysis** - LLM quality metrics
5. **Worker Performance** - Multi-worker tracking

### Handling Failed Documents

```sql
-- View failed documents with errors
SELECT
    document_upload_id,
    file_name,
    error_message,
    retry_count,
    max_retries
FROM document_processing_queue dpq
JOIN document_uploads du ON dpq.document_upload_id = du.id
WHERE dpq.status = 'failed'
ORDER BY dpq.completed_at DESC;
```

**Manual retry:**
```sql
SELECT retry_failed_document('document-uuid-here');
```

**Force re-queue:**
```sql
SELECT manually_queue_document('document-uuid-here', 1);  -- Priority 1 (highest)
```

### Logs

**Application logs:**
- File: `document_processor.log`
- Location: Same directory as `document_processor.py`
- Rotation: Manual (consider adding log rotation)

**Useful log snippets:**
```bash
# Tail logs in real-time
tail -f document_processor.log

# Filter for errors only
grep ERROR document_processor.log

# Filter by document ID
grep "doc-uuid" document_processor.log
```

---

## LLM Prompt Customization

### Editing Prompts

Prompts are stored in `llm_prompts.json`. Edit this file to customize extraction behavior.

**Example: Add new field to Scope 2 electricity extraction**

Edit `llm_prompts.json`:
```json
{
  "prompts": {
    "scope2_electricity": {
      "user_prompt": "Extract the following information...\n\n11. **Carbon Intensity**: If mentioned on bill\n..."
      "..."
    }
  }
}
```

**After editing:**
1. No need to restart service (prompts loaded per-request)
2. Test with sample document
3. Verify new field in `extracted_data` JSONB

### Creating New Prompt for Custom Document Type

1. Add new prompt key to `llm_prompts.json`
2. Update `get_prompt_key()` function in `document_processor.py`:

```python
def get_prompt_key(scope: int, upload_type: str) -> Optional[str]:
    scope_type_map = {
        # ... existing mappings ...
        (2, 'gas_bill'): 'scope2_natural_gas',  # NEW
    }
    return scope_type_map.get((scope, upload_type))
```

3. Restart service

---

## Production Deployment

### Running as a Service (Linux)

Create systemd service file: `/etc/systemd/system/document-processor.service`

```ini
[Unit]
Description=Carbon Accounting Document Processor
After=network.target postgresql.service

[Service]
Type=simple
User=your-user
WorkingDirectory=/path/to/DB
Environment="PATH=/path/to/document_processor_env/bin"
ExecStart=/path/to/document_processor_env/bin/python document_processor.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

**Enable and start:**
```bash
sudo systemctl enable document-processor
sudo systemctl start document-processor
sudo systemctl status document-processor
```

**View logs:**
```bash
sudo journalctl -u document-processor -f
```

### Running as a Service (Windows)

Use NSSM (Non-Sucking Service Manager):

1. Download NSSM: https://nssm.cc/download
2. Install service:
```cmd
nssm install DocumentProcessor "C:\path\to\document_processor_env\Scripts\python.exe" "C:\path\to\DB\document_processor.py"
nssm set DocumentProcessor AppDirectory "C:\path\to\DB"
nssm start DocumentProcessor
```

### Scaling with Multiple Workers

To increase throughput, run multiple instances:

**Method 1: Multiple processes**
```bash
# Terminal 1
WORKER_ID=worker1 python document_processor.py

# Terminal 2
WORKER_ID=worker2 python document_processor.py
```

**Method 2: Docker containers**
```yaml
# docker-compose.yml
services:
  document-processor-1:
    build: .
    environment:
      - GROQ_API_KEY=${GROQ_API_KEY}
      - DB_HOST=postgres
      - WORKER_ID=worker1
    restart: always

  document-processor-2:
    build: .
    environment:
      - GROQ_API_KEY=${GROQ_API_KEY}
      - DB_HOST=postgres
      - WORKER_ID=worker2
    restart: always
```

**Groq rate limits:**
- Free tier: 14,400 requests/day ≈ 600/hour ≈ 10/minute
- With 2 workers: ~5 documents/minute/worker
- Consider upgrading to paid tier for higher throughput

---

## Troubleshooting

### Issue: "No matching emission factor"

**Cause:** LLM extracted fuel type doesn't match database fuel_type

**Solution:**
1. Check extracted data:
```sql
SELECT extracted_data->>'fuel_type' FROM document_uploads WHERE id = 'uuid';
```

2. Check available fuel types:
```sql
SELECT DISTINCT fuel_type FROM emission_factors WHERE scope = 1;
```

3. Add fuzzy matching or synonyms in `match_emission_factor_scope1()`

### Issue: "Low confidence score"

**Cause:** Document image quality poor, or unclear data

**Solutions:**
- Improve document scan quality (300+ DPI)
- Enhance prompts in `llm_prompts.json`
- Add manual review for confidence < 0.6

### Issue: "PDF processing failed"

**Cause:** Poppler not installed or not in PATH

**Solution:**
```bash
# Windows: Verify poppler in PATH
where pdfinfo

# Linux: Install poppler
sudo apt-get install poppler-utils
```

### Issue: "Groq API rate limit exceeded"

**Cause:** Free tier limit reached (14,400/day)

**Solutions:**
- Reduce polling frequency (increase `POLL_INTERVAL_SECONDS`)
- Implement request throttling
- Upgrade to paid Groq plan
- Switch to local Ollama (no rate limits)

### Issue: "Database connection timeout"

**Cause:** Network issues or database overload

**Solution:**
1. Check database connection:
```bash
psql -U postgres -h localhost -d carbon_accounting
```

2. Increase connection timeout in `DATABASE_CONFIG`
3. Verify firewall/network settings

---

## Performance Optimization

### 1. Batch Processing
Modify `document_processor.py` to process multiple documents per poll:

```python
# In main() function
documents = get_next_queued_documents(conn, limit=5)  # Process 5 at once
for document in documents:
    process_document(document)
```

### 2. Async Processing
Use `asyncio` for concurrent API calls:

```python
import asyncio
from groq import AsyncGroq

async def process_document_async(document):
    # Async implementation
    pass
```

### 3. Caching Emission Factors
Cache frequently used emission factors in memory:

```python
from functools import lru_cache

@lru_cache(maxsize=128)
def get_cached_emission_factor(fuel_type, scope):
    # Cache emission factor lookups
    pass
```

---

## Cost Analysis

### Groq Free Tier (Recommended)
- **Cost:** $0/month
- **Limits:** 14,400 requests/day
- **Throughput:** ~600 documents/hour (with breaks)
- **Best for:** <10,000 documents/month

### Groq Paid Tier
- **Cost:** $0.05 - $0.15 per 1M tokens (pricing varies)
- **Limits:** Much higher rate limits
- **Best for:** >10,000 documents/month

### Ollama (Local - FREE)
- **Cost:** $0 (one-time GPU hardware cost)
- **Requirements:** NVIDIA GPU with 8GB+ VRAM
- **Throughput:** ~30-50 tokens/sec (slower than Groq)
- **Best for:** On-premise deployments, no internet

### HuggingFace Inference API
- **Cost:** Free tier available (limited)
- **Limits:** 1,000 requests/day (free)
- **Best for:** Testing/prototyping

---

## Security Best Practices

1. **Environment Variables:** Never hardcode API keys
2. **Database Access:** Use read-only user for emission factor matching
3. **File Access:** Validate file paths to prevent directory traversal
4. **Input Validation:** Sanitize extracted data before insertion
5. **Logging:** Don't log sensitive data (costs, personal info)
6. **Network:** Use TLS/SSL for database connections in production
7. **API Keys:** Rotate Groq API keys regularly

---

## Next Steps

1. ✅ Install PostgreSQL triggers
2. ✅ Set up Python environment
3. ✅ Configure Groq API key
4. ✅ Test with sample document
5. ⬜ Deploy as production service
6. ⬜ Set up monitoring dashboard
7. ⬜ Train team on manual review workflow
8. ⬜ Implement Scope 3 processing (when function ready)

---

## Support and Resources

- **Groq Documentation:** https://console.groq.com/docs
- **Llama 3.2 Model Card:** https://huggingface.co/meta-llama/Llama-3.2-11B-Vision
- **PostgreSQL Triggers:** https://www.postgresql.org/docs/current/trigger-definition.html
- **psycopg2 Documentation:** https://www.psycopg.org/docs/

---

## Appendix: Sample Test Data

### Test Document Upload

```sql
-- Insert test electricity bill
INSERT INTO document_uploads (
    organization_id,
    site_id,
    scope,
    upload_type,
    file_name,
    file_path,
    file_type,
    file_size_kb,
    uploaded_by
) VALUES (
    (SELECT id FROM organizations LIMIT 1),
    (SELECT id FROM sites WHERE country_code = 'GBR' LIMIT 1),
    2,
    'utility_bill',
    'test_electricity_bill.pdf',
    '/path/to/test_electricity_bill.pdf',
    'pdf',
    150,
    (SELECT id FROM users LIMIT 1)
);

-- Check if queued
SELECT * FROM document_processing_queue ORDER BY created_at DESC LIMIT 1;
```

### Expected Workflow Timeline

1. **T+0s:** Document inserted into `document_uploads`
2. **T+0s:** Trigger adds to `document_processing_queue` (status: queued)
3. **T+10s:** Python service polls and finds document (status: processing)
4. **T+13s:** Groq API returns extracted data
5. **T+14s:** Emission factor matched
6. **T+15s:** `insert_scope2_emission()` called
7. **T+16s:** Document linked (status: completed)

**Total processing time:** ~6 seconds per document

---

End of Setup Guide
