# n8n Integration Guide for Carbon Accounting System

## What is n8n?

n8n is an open-source workflow automation tool that allows you to connect different applications and services without writing code. Think of it as a visual programming tool for creating automated workflows.

**Key Benefits for Your System:**
- ✅ Visual workflow builder (no coding required)
- ✅ 400+ pre-built integrations (PostgreSQL, Groq, SharePoint, Email, etc.)
- ✅ Self-hosted (full data control)
- ✅ FREE and open-source
- ✅ Can replace or complement your Python/C# services
- ✅ Built-in scheduling, error handling, retries
- ✅ Real-time monitoring dashboard

## How n8n Fits into Your Current System

### **Current Architecture:**
```
SharePoint → document_uploads table → Python/C# Service → Groq API → emissions tables
```

### **With n8n:**
```
SharePoint → n8n → document_uploads → n8n → Groq API → n8n → emissions tables → n8n → Notifications
         ↓
    Visual monitoring, logging, error handling, scheduling
```

---

## Installation Options

### **Option 1: Docker (Recommended for Production)**

#### Step 1: Create `docker-compose.yml`

```yaml
version: '3.8'

services:
  n8n:
    image: n8nio/n8n:latest
    container_name: n8n
    restart: always
    ports:
      - "5678:5678"
    environment:
      # Basic Auth
      - N8N_BASIC_AUTH_ACTIVE=true
      - N8N_BASIC_AUTH_USER=admin
      - N8N_BASIC_AUTH_PASSWORD=YourSecurePassword123

      # Server Config
      - N8N_HOST=localhost
      - N8N_PORT=5678
      - N8N_PROTOCOL=http
      - WEBHOOK_URL=http://localhost:5678/

      # PostgreSQL for n8n data
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=your_postgres_host
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=n8n
      - DB_POSTGRESDB_USER=n8n_user
      - DB_POSTGRESDB_PASSWORD=n8n_password

      # Timezone
      - GENERIC_TIMEZONE=Asia/Dubai
      - TZ=Asia/Dubai

      # Execution
      - EXECUTIONS_DATA_SAVE_ON_ERROR=all
      - EXECUTIONS_DATA_SAVE_ON_SUCCESS=all
      - EXECUTIONS_DATA_SAVE_MANUAL_EXECUTIONS=true

    volumes:
      - n8n_data:/home/node/.n8n
      - /path/to/your/documents:/documents  # Mount document folder
      - /usr/bin/pdftoppm:/usr/bin/pdftoppm  # Poppler for PDF conversion
      - /usr/bin/pdfinfo:/usr/bin/pdfinfo

volumes:
  n8n_data:
    driver: local
```

#### Step 2: Create n8n Database in PostgreSQL

```sql
-- Run in pgAdmin
CREATE DATABASE n8n;
CREATE USER n8n_user WITH PASSWORD 'n8n_password';
GRANT ALL PRIVILEGES ON DATABASE n8n TO n8n_user;
```

#### Step 3: Start n8n

```bash
# Navigate to folder with docker-compose.yml
cd /path/to/n8n

# Start n8n
docker-compose up -d

# Check logs
docker-compose logs -f n8n

# Access at http://localhost:5678
```

### **Option 2: npm Installation (Quick Testing)**

```bash
# Install globally
npm install n8n -g

# Start n8n
n8n start

# Access at http://localhost:5678
```

### **Option 3: Desktop App (Windows/Mac)**

Download from: https://n8n.io/download

---

## Setup Configuration

### **1. Environment Variables (.env file)**

Create `.env` file in your n8n directory:

```bash
# Groq API
GROQ_API_KEY=your_groq_api_key

# PostgreSQL Carbon Database
CARBON_DB_HOST=localhost
CARBON_DB_PORT=5432
CARBON_DB_NAME=carbon_accounting
CARBON_DB_USER=your_user
CARBON_DB_PASSWORD=your_password

# Organization Settings
ORG_ID=your_org_id
FACILITY_ID=your_facility_id

# File Paths
DOCUMENT_UPLOAD_PATH=/path/to/sharepoint/documents
POPPLER_PATH=/usr/bin

# Email Alerts
SMTP_HOST=smtp.gmail.com
SMTP_PORT=587
SMTP_USER=alerts@yourcompany.com
SMTP_PASSWORD=your_email_password
```

### **2. PostgreSQL Credentials in n8n**

1. Open n8n at `http://localhost:5678`
2. Click **Settings** → **Credentials** → **New Credential**
3. Search for **PostgreSQL**
4. Add connection details:
   - Host: `localhost`
   - Database: `carbon_accounting`
   - User: `your_user`
   - Password: `your_password`
   - Port: `5432`
   - SSL: `Allow`
5. Click **Save**

### **3. Groq API Credentials**

1. **Settings** → **Credentials** → **New Credential**
2. Search for **HTTP Header Auth**
3. Add:
   - Name: `Groq API`
   - Header Name: `Authorization`
   - Header Value: `Bearer your_groq_api_key`
4. Click **Save**

---

## Import Ready-Made Workflows

### **Workflow 1: Document Processing**

1. Download `n8n_document_processing_workflow.json` from the repository
2. In n8n, click **Workflows** → **Import from File**
3. Select the JSON file
4. Click **Import**

**What it does:**
- Polls `document_uploads` table every minute
- Converts PDF to image using Poppler
- Calls Groq Vision API
- Extracts data (supplier, consumption, dates, cost)
- Inserts into `emissions_scope_1/2/3`
- Updates document status
- Sends email if confidence < 70%

### **Workflow 2: UAE Climate Report Generation**

Create this workflow manually:

```
Workflow Steps:
1. Cron Trigger (Monthly: 0 0 1 * *)
2. PostgreSQL: Query emissions data
3. HTTP Request: Call Groq API for narrative
4. Code: Combine data + narrative
5. Execute Command: Generate Word document
6. Email: Send to stakeholders
```

### **Workflow 3: SharePoint File Monitor**

```
Workflow Steps:
1. Webhook or Schedule (Poll every 5 minutes)
2. SharePoint: List files in folder
3. IF: Check if file is new
4. PostgreSQL: Insert into document_uploads
5. PostgreSQL: Insert into document_processing_queue
```

---

## Specific Use Cases

### **Use Case 1: Replace Python/C# Document Processor**

**Advantages:**
- ✅ Visual monitoring dashboard
- ✅ No need to maintain Python/C# code
- ✅ Built-in error handling & retries
- ✅ Easy to modify workflows without redeploying

**Disadvantages:**
- ❌ Slightly slower (HTTP overhead)
- ❌ Less control over execution flow

**Recommendation:** Use n8n for orchestration, keep Python/C# for heavy processing

### **Use Case 2: Scheduled UAE Climate Reports**

```yaml
Trigger: Cron (1st of every quarter)
Step 1: Query emissions_scope_1/2/3
Step 2: Query reduction_measures
Step 3: Query climate_risks
Step 4: Call Groq API (5 times for 5 sections)
Step 5: Combine into single report
Step 6: Generate Word document
Step 7: Upload to SharePoint
Step 8: Email to compliance team
```

### **Use Case 3: Real-time Monitoring & Alerts**

```yaml
Trigger: PostgreSQL Trigger (LISTEN/NOTIFY)
Step 1: Listen for processing_errors
Step 2: IF confidence < 70% OR extraction_failed
Step 3: Send Slack/Email alert
Step 4: Log to monitoring dashboard
```

### **Use Case 4: Multi-Source Document Ingestion**

```yaml
Trigger: Webhook
Step 1: Receive file from Email/SharePoint/Google Drive/OneDrive
Step 2: Detect document type (electricity/fuel/waste)
Step 3: Route to appropriate LLM prompt
Step 4: Process and insert
```

---

## n8n vs Python/C# Comparison

| Feature | Python/C# Service | n8n |
|---------|-------------------|-----|
| **Visual Monitoring** | ❌ Need custom dashboard | ✅ Built-in |
| **Error Handling** | ⚠️ Manual implementation | ✅ Built-in retry logic |
| **Scheduling** | ⚠️ Need cron/Windows Task | ✅ Built-in cron |
| **Modifications** | ❌ Need code changes + redeploy | ✅ Visual editor |
| **Performance** | ✅ Faster (direct execution) | ⚠️ Slightly slower |
| **Complex Logic** | ✅ Full programming capability | ⚠️ Limited to nodes |
| **API Integrations** | ⚠️ Manual HTTP requests | ✅ 400+ pre-built nodes |
| **Email/Slack Alerts** | ⚠️ Manual implementation | ✅ Built-in nodes |
| **Database Operations** | ✅ Full control | ✅ Visual query builder |
| **Cost** | ✅ Free | ✅ Free (self-hosted) |

---

## Recommended Hybrid Approach

**Best of Both Worlds:**

```
n8n (Orchestration Layer)
    ↓
Triggers workflows, handles scheduling, routing
    ↓
Python/C# (Processing Layer)
    ↓
Heavy computation, complex logic, batch processing
    ↓
n8n (Notification Layer)
    ↓
Email, Slack, dashboards, logging
```

**Example:**
```yaml
n8n Workflow:
1. Cron Trigger (Every 5 minutes)
2. PostgreSQL: Get pending documents
3. HTTP Request: Call your Python/C# API endpoint
4. Wait for response
5. IF success → Update status, send confirmation
6. IF error → Retry 3 times, then alert team
```

---

## Advanced Features

### **1. Error Recovery with Retries**

```yaml
Error Trigger Node:
  Retry on Error: Yes
  Retry Times: 3
  Retry Wait: 300 seconds
  On Error: Send to Error Workflow
```

### **2. Parallel Processing**

```yaml
Split Node:
  Input: 100 documents
  Parallel Batches: 10
  Process: 10 documents at a time
  Merge results
```

### **3. Webhooks for Real-time Processing**

```python
# Python trigger script
import requests

requests.post('http://localhost:5678/webhook/process-document', json={
    'document_id': 123,
    'file_path': '/uploads/bill.pdf',
    'scope': 2
})
```

### **4. Custom Code Nodes (JavaScript)**

```javascript
// Extract and transform data
const items = $input.all();

return items.map(item => {
  return {
    json: {
      document_id: item.json.id,
      emission_factor: calculateEmissionFactor(item.json),
      co2e: item.json.consumption * getEmissionFactor()
    }
  };
});
```

---

## Performance Optimization

### **1. Batch Processing**

```yaml
Instead of: Process 1 document per execution
Use: Process 10 documents in parallel
```

### **2. Database Connection Pooling**

```yaml
PostgreSQL Node Settings:
  Connection Pool: Yes
  Max Connections: 10
```

### **3. Cache LLM Prompts**

```yaml
Static Data Node:
  Cache LLM prompts in memory
  Reuse across executions
```

---

## Monitoring & Logging

### **Built-in Dashboard**

Access at `http://localhost:5678/executions`

**View:**
- ✅ Execution history (last 7 days)
- ✅ Success/failure rates
- ✅ Execution time per node
- ✅ Error logs with stack traces
- ✅ Input/output data for each step

### **Custom Logging**

```yaml
Function Node:
  console.log('Processing document:', $json.id);
  console.log('Confidence:', $json.confidence);
```

---

## Security Best Practices

1. **Use Environment Variables**
   - Never hardcode API keys in workflows
   - Store in `.env` file

2. **Enable Authentication**
   ```yaml
   N8N_BASIC_AUTH_ACTIVE=true
   ```

3. **Use HTTPS in Production**
   ```yaml
   N8N_PROTOCOL=https
   ```

4. **Restrict Network Access**
   - Use firewall rules
   - Only allow PostgreSQL from n8n IP

5. **Encrypt Credentials**
   - n8n encrypts credentials by default
   - Use `N8N_ENCRYPTION_KEY` for production

---

## Quick Start Checklist

- [ ] Install Docker + Docker Compose
- [ ] Create `docker-compose.yml`
- [ ] Create n8n database in PostgreSQL
- [ ] Start n8n: `docker-compose up -d`
- [ ] Access at `http://localhost:5678`
- [ ] Add PostgreSQL credentials
- [ ] Add Groq API credentials
- [ ] Import `n8n_document_processing_workflow.json`
- [ ] Test with sample document
- [ ] Monitor execution in dashboard
- [ ] Set up email alerts

---

## Example Workflows to Build

### **1. Daily Emissions Summary Email**

```yaml
Trigger: Cron (Every day at 8 AM)
Step 1: Query yesterday's emissions
Step 2: Calculate totals by scope
Step 3: Generate HTML table
Step 4: Email to management
```

### **2. Automatic Emission Factor Updates**

```yaml
Trigger: Cron (Monthly)
Step 1: Web scraping (EPA, DEFRA websites)
Step 2: Parse emission factors
Step 3: Compare with database
Step 4: IF changed → Update + notify team
```

### **3. Document Quality Check**

```yaml
Trigger: After document processing
Step 1: Check if all required fields extracted
Step 2: Validate date ranges
Step 3: Cross-check with previous bills
Step 4: IF anomaly → Flag for review
```

---

## Troubleshooting

### **Issue 1: n8n can't connect to PostgreSQL**

```bash
# Check if PostgreSQL allows connections from Docker
# Edit postgresql.conf:
listen_addresses = '*'

# Edit pg_hba.conf:
host    all    all    172.17.0.0/16    md5

# Restart PostgreSQL
sudo systemctl restart postgresql
```

### **Issue 2: Poppler not found in Docker**

```dockerfile
# Add to docker-compose.yml
services:
  n8n:
    volumes:
      - /usr/bin/pdftoppm:/usr/bin/pdftoppm
      - /usr/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu
```

### **Issue 3: Groq API timeout**

```yaml
HTTP Request Node:
  Timeout: 60000  # Increase to 60 seconds
  Retry on Fail: Yes
```

---

## Next Steps

1. **Start Simple**: Import the document processing workflow
2. **Test**: Process 1-2 documents manually
3. **Monitor**: Check execution logs
4. **Expand**: Add email notifications, Slack alerts
5. **Optimize**: Batch processing, parallel execution
6. **Replace**: Gradually replace Python/C# with n8n workflows

---

## Resources

- **n8n Documentation**: https://docs.n8n.io
- **Community Forum**: https://community.n8n.io
- **YouTube Tutorials**: https://www.youtube.com/@n8n-io
- **Workflow Templates**: https://n8n.io/workflows

---

## Support

If you encounter issues:
1. Check n8n logs: `docker-compose logs -f n8n`
2. Visit community forum: https://community.n8n.io
3. GitHub issues: https://github.com/n8n-io/n8n/issues
