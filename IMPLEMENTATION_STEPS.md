# 🚀 Document Processing System - Step-by-Step Implementation

## 📋 **Your Current Setup**
✅ PostgreSQL + pgAdmin installed
✅ Database `carbon_accounting` restored
✅ SharePoint/file storage configured (assumed)
⏭️ Need to implement: LLM document processing

---

## ⚡ **Quick Overview**

This system will:
1. **Auto-queue** uploaded documents via PostgreSQL triggers
2. **Extract data** using Groq's FREE LLM API (Llama 3.2 11B Vision)
3. **Auto-insert** emissions into your database
4. **Link** documents to emission records

**Processing time:** ~6 seconds per document
**Cost:** $0/month (free tier: 14,400 docs/day)

---

## 🔧 **PHASE 1: Database Setup (10 minutes)**

### **Step 1.1: Install Database Triggers**

Open pgAdmin and connect to your `carbon_accounting` database.

**Option A: Using pgAdmin Query Tool**
1. Click on your `carbon_accounting` database
2. Click **Tools** → **Query Tool**
3. Open the file: `create_document_processing_triggers.sql`
4. Click **Execute** (F5)

**Option B: Using psql command line**
```bash
psql -U postgres -d carbon_accounting -f create_document_processing_triggers.sql
```

**Expected Output:**
```
✅ DOCUMENT PROCESSING TRIGGERS INSTALLED SUCCESSFULLY
```

### **Step 1.2: Verify Installation**

Run this query in pgAdmin:

```sql
-- Check functions were created
SELECT routine_name
FROM information_schema.routines
WHERE routine_name LIKE '%document%'
  AND routine_schema = 'public';
```

**Expected Results** (6 functions):
- `auto_queue_document_for_processing`
- `update_document_on_queue_change`
- `link_emission_to_document`
- `retry_failed_document`
- `manually_queue_document`
- `get_queue_health`

```sql
-- Check triggers were created
SELECT trigger_name, event_object_table
FROM information_schema.triggers
WHERE trigger_name LIKE '%document%';
```

**Expected Results** (2 triggers):
- `trigger_auto_queue_document` on `document_uploads`
- `trigger_update_document_status` on `document_processing_queue`

### **Step 1.3: Test Auto-Queuing (Optional)**

```sql
-- Insert a test document (no actual file needed for this test)
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
    (SELECT id FROM sites LIMIT 1),
    2,  -- Scope 2
    'utility_bill',
    'test_bill.pdf',
    '/test/test_bill.pdf',
    'pdf',
    100,
    (SELECT id FROM users LIMIT 1)
) RETURNING id;

-- Check if it was auto-queued
SELECT
    du.file_name,
    dpq.status,
    dpq.priority
FROM document_uploads du
JOIN document_processing_queue dpq ON dpq.document_upload_id = du.id
ORDER BY du.created_at DESC
LIMIT 1;
```

**Expected:** Status = 'queued', Priority = 3

✅ **Phase 1 Complete!** Database triggers are installed.

---

## 🐍 **PHASE 2: Python Service Setup (15 minutes)**

### **Step 2.1: Check Python Version**

```bash
python --version
# Should show: Python 3.9.x or higher
```

If Python < 3.9, download from https://www.python.org/downloads/

### **Step 2.2: Create Virtual Environment**

```bash
# Navigate to your DB folder
cd C:\Users\YourUser\Desktop\DB-BAckup
# Or on Linux/Mac:
cd /home/user/DB-BAckup

# Create virtual environment
python -m venv document_processor_env

# Activate it
# Windows:
document_processor_env\Scripts\activate

# Linux/Mac:
source document_processor_env/bin/activate
```

You should see `(document_processor_env)` in your terminal.

### **Step 2.3: Install Python Dependencies**

```bash
pip install -r requirements.txt
```

**This installs:**
- `groq` - Groq API client
- `psycopg2-binary` - PostgreSQL connector
- `pdf2image` - PDF processing
- `Pillow` - Image processing
- `python-dotenv` - Environment variables

### **Step 2.4: Install Poppler (PDF Processing)**

**Windows:**
1. Download: https://github.com/oschwartz10612/poppler-windows/releases/
2. Extract to: `C:\Program Files\poppler`
3. Add to PATH:
   - Search → "Environment Variables"
   - System Variables → Path → Edit
   - Add: `C:\Program Files\poppler\Library\bin`
   - Click OK
4. Restart terminal

**Linux (Ubuntu/Debian):**
```bash
sudo apt-get update
sudo apt-get install poppler-utils
```

**Mac:**
```bash
brew install poppler
```

**Verify installation:**
```bash
# Windows:
where pdfinfo

# Linux/Mac:
which pdfinfo
```

Should show the path to pdfinfo executable.

---

## 🔑 **PHASE 3: Get Groq API Key (5 minutes - FREE)**

### **Step 3.1: Sign Up for Groq**

1. Go to: https://console.groq.com/
2. Click **Sign Up** (it's FREE)
3. Use Google/GitHub account or email
4. Verify email

### **Step 3.2: Create API Key**

1. Go to: https://console.groq.com/keys
2. Click **Create API Key**
3. Name it: `Carbon Accounting Document Processor`
4. Click **Create**
5. **COPY THE KEY** (starts with `gsk_...`)
   - ⚠️ You can only see it once!

**Free Tier Limits:**
- 14,400 requests/day
- ~600 documents/hour
- No credit card required

### **Step 3.3: Create .env File**

Create a file named `.env` in your `DB-BAckup` folder:

```bash
# .env file
GROQ_API_KEY=gsk_your_actual_key_here

# Database Configuration
DB_HOST=localhost
DB_PORT=5432
DB_NAME=carbon_accounting
DB_USER=postgres
DB_PASSWORD=your_postgres_password_here

# Optional
LOG_LEVEL=INFO
POLL_INTERVAL_SECONDS=10
```

**Replace:**
- `gsk_your_actual_key_here` with your actual Groq API key
- `your_postgres_password_here` with your PostgreSQL password

**⚠️ Security:**
- Never commit `.env` to Git
- Add `.env` to `.gitignore`

### **Step 3.4: Test Database Connection**

```bash
python -c "import psycopg2; import os; from dotenv import load_dotenv; load_dotenv(); conn = psycopg2.connect(host=os.getenv('DB_HOST'), database=os.getenv('DB_NAME'), user=os.getenv('DB_USER'), password=os.getenv('DB_PASSWORD')); print('✅ Database connection successful!'); conn.close()"
```

**Expected:** `✅ Database connection successful!`

### **Step 3.5: Test Groq API**

```bash
python -c "from groq import Groq; import os; from dotenv import load_dotenv; load_dotenv(); client = Groq(api_key=os.getenv('GROQ_API_KEY')); print('✅ Groq API connected!'); response = client.chat.completions.create(messages=[{'role': 'user', 'content': 'Hello'}], model='llama-3.2-11b-text-preview'); print(response.choices[0].message.content)"
```

**Expected:** `✅ Groq API connected!` followed by a response from the LLM.

✅ **Phase 3 Complete!** API access configured.

---

## 📝 **PHASE 4: Create Required Files**

I need to create the following files for you. Let me know if you want me to create them now:

### **Files Needed:**

1. **`document_processor.py`** - Main Python service (~650 lines)
   - Polls database queue
   - Calls Groq API
   - Extracts data
   - Inserts emissions

2. **`llm_prompts.json`** - LLM prompts for different document types
   - Scope 1: Fuel combustion, Waste
   - Scope 2: Electricity, Heat/Steam/Cooling
   - Scope 3: Logistics (future)

3. **`monitor_document_processing.sql`** - Monitoring queries
   - Queue health dashboard
   - Failed documents
   - Performance metrics

**Would you like me to create these files now?**

---

## 🚀 **PHASE 5: Running the Service**

### **Step 5.1: Start the Document Processor**

```bash
# Make sure virtual environment is activated
python document_processor.py
```

**Expected Output:**
```
2025-11-06 10:00:00 - INFO - Document processor started (worker: worker_abc123)
2025-11-06 10:00:00 - INFO - Polling interval: 10 seconds
2025-11-06 10:00:10 - DEBUG - No documents in queue, waiting...
```

**Service Behavior:**
- Polls database every 10 seconds
- Processes documents automatically
- Logs to console and `document_processor.log`
- Press `Ctrl+C` to stop

### **Step 5.2: Test with Real Document**

**In another terminal/pgAdmin:**

```sql
-- Upload a real electricity bill
INSERT INTO document_uploads (
    organization_id,
    site_id,
    scope,
    upload_type,
    file_name,
    file_path,  -- Must be actual path to PDF/image
    file_type,
    file_size_kb,
    uploaded_by
) VALUES (
    (SELECT id FROM organizations LIMIT 1),
    (SELECT id FROM sites WHERE country_code = 'GBR' LIMIT 1),
    2,  -- Scope 2 Electricity
    'utility_bill',
    'electricity_jan_2024.pdf',
    'C:\Documents\electricity_jan_2024.pdf',  -- Your actual file path
    'pdf',
    250,
    (SELECT id FROM users LIMIT 1)
);
```

**Watch the service logs:**
```
2025-11-06 10:00:20 - INFO - Processing document: electricity_jan_2024.pdf
2025-11-06 10:00:22 - INFO - Calling Groq API for extraction...
2025-11-06 10:00:25 - INFO - Extracted data with confidence: 0.92
2025-11-06 10:00:26 - INFO - Matched emission factor for Electricity
2025-11-06 10:00:27 - INFO - Inserted Scope 2 emission successfully
2025-11-06 10:00:27 - INFO - ✅ Processing completed in 7.2s
```

### **Step 5.3: Check Results**

```sql
-- View extracted data
SELECT
    file_name,
    extraction_status,
    extraction_confidence_score,
    extracted_data,
    linked_emission_entry_id
FROM document_uploads
WHERE file_name = 'electricity_jan_2024.pdf';

-- View created emission record
SELECT * FROM emissions_scope_2
WHERE id = (
    SELECT linked_emission_entry_id
    FROM document_uploads
    WHERE file_name = 'electricity_jan_2024.pdf'
);
```

✅ **Phase 5 Complete!** System is processing documents!

---

## 📊 **PHASE 6: Monitoring**

### **Quick Health Check**

```sql
SELECT * FROM get_queue_health();
```

**Output:**
```
metric                    | value
--------------------------+-------
queued_documents          | 5
processing_documents      | 1
failed_documents_24h      | 0
avg_processing_time_ms    | 6500
success_rate_24h_pct      | 100.00
```

### **View Recent Activity**

```sql
-- Last 10 processed documents
SELECT
    du.file_name,
    du.extraction_status,
    du.extraction_confidence_score,
    dpq.processing_time_ms,
    dpq.status
FROM document_uploads du
JOIN document_processing_queue dpq ON dpq.document_upload_id = du.id
ORDER BY du.uploaded_at DESC
LIMIT 10;
```

### **Check Failed Documents**

```sql
SELECT
    du.file_name,
    dpq.error_message,
    dpq.retry_count
FROM document_uploads du
JOIN document_processing_queue dpq ON dpq.document_upload_id = du.id
WHERE dpq.status = 'failed'
ORDER BY dpq.completed_at DESC;
```

### **Retry Failed Document**

```sql
SELECT retry_failed_document('document-uuid-here');
```

---

## ⚙️ **PHASE 7: Production Deployment (Optional)**

### **Option A: Run as Windows Service (NSSM)**

1. Download NSSM: https://nssm.cc/download
2. Install service:
```cmd
nssm install DocumentProcessor "C:\path\to\document_processor_env\Scripts\python.exe" "C:\path\to\DB-BAckup\document_processor.py"
nssm set DocumentProcessor AppDirectory "C:\path\to\DB-BAckup"
nssm start DocumentProcessor
```

### **Option B: Run as Linux Service (systemd)**

Create `/etc/systemd/system/document-processor.service`:

```ini
[Unit]
Description=Carbon Accounting Document Processor
After=network.target postgresql.service

[Service]
Type=simple
User=your-user
WorkingDirectory=/home/user/DB-BAckup
Environment="PATH=/home/user/DB-BAckup/document_processor_env/bin"
ExecStart=/home/user/DB-BAckup/document_processor_env/bin/python document_processor.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl enable document-processor
sudo systemctl start document-processor
sudo systemctl status document-processor
```

---

## 🔧 **Troubleshooting**

### **Issue: "No module named 'groq'"**
**Solution:**
```bash
pip install groq
```

### **Issue: "GROQ_API_KEY not found"**
**Solution:**
1. Check `.env` file exists
2. Verify key starts with `gsk_`
3. Restart Python script

### **Issue: "No matching emission factor"**
**Solution:**
```sql
-- Check emission factors exist
SELECT * FROM emission_factors
WHERE scope = 2 AND is_active = true;

-- If empty, you need to ingest emission factors first
```

### **Issue: "PDF processing failed"**
**Solution:**
- Verify poppler is installed: `where pdfinfo` (Windows) or `which pdfinfo` (Linux)
- Check PATH contains poppler bin directory

### **Issue: Document stuck in "processing"**
**Solution:**
```sql
-- Force re-queue
UPDATE document_processing_queue
SET status = 'queued', started_at = NULL, worker_id = NULL
WHERE document_upload_id = 'stuck-doc-uuid';
```

---

## ✅ **Implementation Checklist**

- [ ] Phase 1: Database triggers installed
- [ ] Phase 2: Python environment setup
- [ ] Phase 3: Groq API key configured
- [ ] Phase 4: Python service files created
- [ ] Phase 5: Service running and processing documents
- [ ] Phase 6: Monitoring queries tested
- [ ] Phase 7: Production deployment (optional)

---

## 📞 **Next Steps**

1. **Tell me if you want me to create the Python files** (`document_processor.py`, `llm_prompts.json`, `monitor_document_processing.sql`)

2. **Test with sample documents** from your SharePoint

3. **Monitor performance** using the dashboard queries

4. **Iterate on prompts** based on extraction accuracy

5. **Scale if needed** by adding more worker instances

---

## 📚 **Quick Reference**

**Start Service:**
```bash
python document_processor.py
```

**Check Health:**
```sql
SELECT * FROM get_queue_health();
```

**Retry Failed:**
```sql
SELECT retry_failed_document('doc-uuid');
```

**View Logs:**
```bash
tail -f document_processor.log
```

---

**Ready to proceed? Let me know if you want me to create the Python service files!**
