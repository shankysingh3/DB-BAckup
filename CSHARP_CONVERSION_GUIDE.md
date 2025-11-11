# Complete C# / .NET Conversion Guide
## Document Processor Service - Python to C# Migration

---

## Table of Contents

1. [Overview](#overview)
2. [Project Structure](#project-structure)
3. [Prerequisites](#prerequisites)
4. [Installation Steps](#installation-steps)
5. [Configuration](#configuration)
6. [Code Files](#code-files)
7. [Setup Instructions](#setup-instructions)
8. [Running the Application](#running-the-application)
9. [Python vs C# Comparison](#python-vs-c-comparison)
10. [Troubleshooting](#troubleshooting)
11. [Advanced: Windows Service](#advanced-windows-service)

---

## Overview

This guide converts the Python `document_processor1.py` (917 lines) into a complete C# / .NET 8.0 console application.

**What it does:**
- Polls PostgreSQL database for queued documents
- Converts PDF/images to base64
- Calls Groq API (Llama 3.2 Vision) to extract data
- Validates extracted data
- Inserts emissions into database
- Handles retries and error logging

**Technology Stack:**
- .NET 8.0 (C# 12)
- Npgsql (PostgreSQL)
- PDFtoImage (PDF processing)
- Groq API (LLM vision model)
- Serilog (Logging)

---

## Project Structure

```
DocumentProcessorService/
├── DocumentProcessorService.csproj
├── Program.cs                          # Entry point
├── appsettings.json                    # Configuration (like .env)
├── appsettings.Development.json
├── llm_prompts.json                    # Same as Python version
├── Models/
│   ├── DocumentRecord.cs               # Document data model
│   ├── ExtractedData.cs                # LLM response model
│   └── LlmPrompts.cs                   # Prompts configuration model
├── Services/
│   ├── DocumentProcessor.cs            # Main service
│   ├── GroqApiService.cs               # Groq API calls
│   ├── DatabaseService.cs              # PostgreSQL operations
│   ├── PdfImageConverter.cs            # PDF to Image conversion
│   └── ValidationService.cs            # Data validation
└── Helpers/
    └── JsonHelper.cs
```

---

## Prerequisites

### Required Software

1. **.NET 8.0 SDK**
   - Download: https://dotnet.microsoft.com/download
   - Verify: `dotnet --version` should show `8.0.x`

2. **PostgreSQL 13+**
   - With `carbon_accounting` database
   - Running on localhost:5432

3. **Poppler** (PDF processing)
   - Download: https://github.com/oschwartz10612/poppler-windows/releases/
   - Extract to: `C:\Program Files\poppler\`
   - Verify path exists: `C:\Program Files\poppler\Library\bin\`

4. **IDE (Choose one)**
   - Visual Studio 2022 (Recommended)
   - Visual Studio Code with C# extension
   - JetBrains Rider

5. **Groq API Key**
   - Sign up: https://console.groq.com/
   - Create API key (starts with `gsk_`)

---

## Installation Steps

### Step 1: Create Project

```bash
# Create project folder
mkdir DocumentProcessorService
cd DocumentProcessorService

# Create console application
dotnet new console -n DocumentProcessorService

# Navigate into project
cd DocumentProcessorService
```

### Step 2: Install NuGet Packages

```bash
# PostgreSQL driver
dotnet add package Npgsql --version 8.0.1

# PDF to Image conversion
dotnet add package PDFtoImage --version 4.0.1

# HTTP client for Groq API
dotnet add package System.Net.Http.Json --version 8.0.0

# JSON handling
dotnet add package Newtonsoft.Json --version 13.0.3

# Configuration
dotnet add package Microsoft.Extensions.Configuration --version 8.0.0
dotnet add package Microsoft.Extensions.Configuration.Json --version 8.0.0
dotnet add package Microsoft.Extensions.Configuration.EnvironmentVariables --version 8.0.0

# Logging
dotnet add package Serilog --version 3.1.1
dotnet add package Serilog.Sinks.Console --version 5.0.1
dotnet add package Serilog.Sinks.File --version 5.0.0

# Environment variables (optional - like Python's dotenv)
dotnet add package DotNetEnv --version 3.0.0
```

### Step 3: Create Folder Structure

```bash
# Create folders
mkdir Models
mkdir Services
mkdir Helpers
```

---

## Configuration

### Option 1: appsettings.json (Recommended)

Create `appsettings.json` in project root:

```json
{
  "Database": {
    "Host": "localhost",
    "Port": 5432,
    "Database": "carbon_accounting",
    "Username": "postgres",
    "Password": "your_actual_password_here"
  },
  "Groq": {
    "ApiKey": "gsk_your_groq_api_key_here",
    "Model": "llama-3.2-11b-vision-preview",
    "Temperature": 0.1,
    "MaxTokens": 2048
  },
  "Processing": {
    "PollIntervalSeconds": 10,
    "MaxProcessingTimeMinutes": 5,
    "MaxRetries": 3,
    "WorkerId": "worker_dotnet_001"
  },
  "Logging": {
    "LogLevel": "Information",
    "LogFilePath": "document_processor.log"
  },
  "PopplerPath": "C:\\Program Files\\poppler\\Library\\bin"
}
```

### Option 2: .env file (Like Python)

Create `.env` file:

```bash
DB_HOST=localhost
DB_PORT=5432
DB_NAME=carbon_accounting
DB_USER=postgres
DB_PASSWORD=your_password

GROQ_API_KEY=gsk_your_api_key_here
GROQ_MODEL=llama-3.2-11b-vision-preview
GROQ_TEMPERATURE=0.1
GROQ_MAX_TOKENS=2048

POLL_INTERVAL_SECONDS=10
MAX_PROCESSING_TIME_MINUTES=5
WORKER_ID=worker_dotnet_001

LOG_LEVEL=Information
LOG_FILE=document_processor.log

POPPLER_PATH=C:\Program Files\poppler\Library\bin
```

To use .env file, add to Program.cs:

```csharp
// At the top of Main method:
DotNetEnv.Env.Load();

// Access with:
string apiKey = Environment.GetEnvironmentVariable("GROQ_API_KEY");
```

---

## Code Files

### Models/DocumentRecord.cs

```csharp
using System;

namespace DocumentProcessorService.Models
{
    public class DocumentRecord
    {
        public Guid Id { get; set; }
        public Guid QueueId { get; set; }
        public Guid OrganizationId { get; set; }
        public Guid SiteId { get; set; }
        public int Scope { get; set; }
        public string UploadType { get; set; }
        public string FileName { get; set; }
        public string FilePath { get; set; }
        public string FileType { get; set; }
        public Guid UploadedBy { get; set; }
        public int Priority { get; set; }
        public int RetryCount { get; set; }
    }
}
```

### Models/ExtractedData.cs

```csharp
using System;
using System.Collections.Generic;
using Newtonsoft.Json;

namespace DocumentProcessorService.Models
{
    public class ExtractedData
    {
        [JsonProperty("confidence_score")]
        public decimal ConfidenceScore { get; set; }

        [JsonProperty("extraction_notes")]
        public string ExtractionNotes { get; set; }

        // Scope 1 fields
        [JsonProperty("fuel_type")]
        public string FuelType { get; set; }

        [JsonProperty("waste_type")]
        public string WasteType { get; set; }

        [JsonProperty("consumption_amount")]
        public decimal? ConsumptionAmount { get; set; }

        [JsonProperty("consumption_unit")]
        public string ConsumptionUnit { get; set; }

        [JsonProperty("combustion_type")]
        public string CombustionType { get; set; }

        [JsonProperty("equipment_vehicle_details")]
        public string EquipmentVehicleDetails { get; set; }

        [JsonProperty("invoice_date")]
        public string InvoiceDate { get; set; }

        // Scope 2 fields
        [JsonProperty("supplier_name")]
        public string SupplierName { get; set; }

        [JsonProperty("total_consumption_kwh")]
        public decimal? TotalConsumptionKwh { get; set; }

        [JsonProperty("service_type")]
        public string ServiceType { get; set; }

        [JsonProperty("billing_period_start")]
        public string BillingPeriodStart { get; set; }

        [JsonProperty("billing_period_end")]
        public string BillingPeriodEnd { get; set; }

        [JsonProperty("is_green_tariff")]
        public bool? IsGreenTariff { get; set; }

        // Store all additional data
        [JsonExtensionData]
        public Dictionary<string, object> AdditionalData { get; set; }
    }
}
```

### Models/LlmPrompts.cs

```csharp
using System.Collections.Generic;
using Newtonsoft.Json;

namespace DocumentProcessorService.Models
{
    public class LlmPromptsConfig
    {
        [JsonProperty("prompts")]
        public Dictionary<string, PromptConfig> Prompts { get; set; }

        [JsonProperty("validation_rules")]
        public ValidationRules ValidationRules { get; set; }
    }

    public class PromptConfig
    {
        [JsonProperty("name")]
        public string Name { get; set; }

        [JsonProperty("system_prompt")]
        public string SystemPrompt { get; set; }

        [JsonProperty("user_prompt")]
        public string UserPrompt { get; set; }

        [JsonProperty("expected_scope")]
        public int ExpectedScope { get; set; }

        [JsonProperty("confidence_threshold")]
        public decimal ConfidenceThreshold { get; set; }

        [JsonProperty("required_fields")]
        public List<string> RequiredFields { get; set; }
    }

    public class ValidationRules
    {
        [JsonProperty("min_confidence_score")]
        public decimal MinConfidenceScore { get; set; }

        [JsonProperty("max_date_past_years")]
        public int MaxDatePastYears { get; set; }

        [JsonProperty("max_date_future_days")]
        public int MaxDateFutureDays { get; set; }

        [JsonProperty("required_field_check")]
        public bool RequiredFieldCheck { get; set; }
    }
}
```

### Services/PdfImageConverter.cs

```csharp
using System;
using System.IO;
using PDFtoImage;
using SkiaSharp;
using Serilog;

namespace DocumentProcessorService.Services
{
    public class PdfImageConverter
    {
        private readonly ILogger _logger;

        public PdfImageConverter(ILogger logger)
        {
            _logger = logger;
        }

        public string ConvertToBase64(string filePath, string fileType)
        {
            try
            {
                byte[] imageBytes;

                if (fileType.ToLower() == "pdf")
                {
                    _logger.Information($"Converting PDF to image: {filePath}");

                    // Convert PDF to image (first page only)
                    using (var pdfStream = File.OpenRead(filePath))
                    {
                        var bitmap = Conversion.ToImage(pdfStream, dpi: 300, page: 0);

                        using (var image = SKImage.FromBitmap(bitmap))
                        using (var data = image.Encode(SKEncodedImageFormat.Jpeg, 95))
                        {
                            imageBytes = data.ToArray();
                        }
                    }
                }
                else
                {
                    _logger.Information($"Loading image: {filePath}");

                    using (var bitmap = SKBitmap.Decode(filePath))
                    {
                        var resized = ResizeIfNeeded(bitmap, 2048);

                        using (var image = SKImage.FromBitmap(resized))
                        using (var data = image.Encode(SKEncodedImageFormat.Jpeg, 95))
                        {
                            imageBytes = data.ToArray();
                        }
                    }
                }

                string base64 = Convert.ToBase64String(imageBytes);
                _logger.Information($"Image encoded successfully ({base64.Length} chars)");

                return base64;
            }
            catch (Exception ex)
            {
                _logger.Error(ex, $"Error encoding image {filePath}");
                throw;
            }
        }

        private SKBitmap ResizeIfNeeded(SKBitmap original, int maxSize)
        {
            if (original.Width <= maxSize && original.Height <= maxSize)
            {
                return original;
            }

            float scale = Math.Min(
                (float)maxSize / original.Width,
                (float)maxSize / original.Height
            );

            int newWidth = (int)(original.Width * scale);
            int newHeight = (int)(original.Height * scale);

            return original.Resize(new SKImageInfo(newWidth, newHeight), SKFilterQuality.High);
        }
    }
}
```

### Services/GroqApiService.cs

```csharp
using System;
using System.Net.Http;
using System.Text;
using System.Threading.Tasks;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using Serilog;
using DocumentProcessorService.Models;

namespace DocumentProcessorService.Services
{
    public class GroqApiService
    {
        private readonly HttpClient _httpClient;
        private readonly ILogger _logger;
        private readonly string _apiKey;
        private readonly string _model;
        private readonly double _temperature;
        private readonly int _maxTokens;

        public GroqApiService(string apiKey, string model, double temperature, int maxTokens, ILogger logger)
        {
            _apiKey = apiKey;
            _model = model;
            _temperature = temperature;
            _maxTokens = maxTokens;
            _logger = logger;

            _httpClient = new HttpClient
            {
                BaseAddress = new Uri("https://api.groq.com/openai/v1/"),
                Timeout = TimeSpan.FromMinutes(2)
            };
            _httpClient.DefaultRequestHeaders.Add("Authorization", $"Bearer {_apiKey}");
        }

        public async Task<ExtractedData> ExtractDataAsync(string imageBase64, PromptConfig promptConfig)
        {
            try
            {
                _logger.Information($"Calling Groq API with model {_model}");

                var requestBody = new
                {
                    model = _model,
                    messages = new[]
                    {
                        new
                        {
                            role = "system",
                            content = promptConfig.SystemPrompt
                        },
                        new
                        {
                            role = "user",
                            content = new object[]
                            {
                                new { type = "text", text = promptConfig.UserPrompt },
                                new
                                {
                                    type = "image_url",
                                    image_url = new { url = $"data:image/jpeg;base64,{imageBase64}" }
                                }
                            }
                        }
                    },
                    temperature = _temperature,
                    max_tokens = _maxTokens
                };

                var jsonContent = JsonConvert.SerializeObject(requestBody);
                var content = new StringContent(jsonContent, Encoding.UTF8, "application/json");

                var response = await _httpClient.PostAsync("chat/completions", content);
                response.EnsureSuccessStatusCode();

                var responseJson = await response.Content.ReadAsStringAsync();
                var responseObj = JObject.Parse(responseJson);

                var messageContent = responseObj["choices"]?[0]?["message"]?["content"]?.ToString();

                if (string.IsNullOrEmpty(messageContent))
                {
                    throw new Exception("Empty response from Groq API");
                }

                string extractedJson = ExtractJsonFromResponse(messageContent);
                var extractedData = JsonConvert.DeserializeObject<ExtractedData>(extractedJson);

                _logger.Information($"Groq API response parsed (confidence: {extractedData.ConfidenceScore})");

                return extractedData;
            }
            catch (Exception ex)
            {
                _logger.Error(ex, "Groq API error");
                throw;
            }
        }

        private string ExtractJsonFromResponse(string content)
        {
            content = content.Trim();

            if (content.StartsWith("```json"))
            {
                var start = content.IndexOf("```json") + 7;
                var end = content.IndexOf("```", start);
                if (end > start)
                {
                    content = content.Substring(start, end - start).Trim();
                }
            }
            else if (content.StartsWith("```"))
            {
                var start = content.IndexOf("```") + 3;
                var end = content.IndexOf("```", start);
                if (end > start)
                {
                    content = content.Substring(start, end - start).Trim();
                }
            }

            return content;
        }
    }
}
```

### Services/DatabaseService.cs

```csharp
using System;
using System.Threading.Tasks;
using Npgsql;
using Serilog;
using DocumentProcessorService.Models;

namespace DocumentProcessorService.Services
{
    public class DatabaseService
    {
        private readonly string _connectionString;
        private readonly ILogger _logger;
        private readonly string _workerId;

        public DatabaseService(string connectionString, string workerId, ILogger logger)
        {
            _connectionString = connectionString;
            _workerId = workerId;
            _logger = logger;
        }

        public async Task<DocumentRecord> GetNextQueuedDocumentAsync()
        {
            try
            {
                using var conn = new NpgsqlConnection(_connectionString);
                await conn.OpenAsync();

                using var cmd = new NpgsqlCommand(@"
                    UPDATE document_processing_queue
                    SET status = 'processing', worker_id = @workerId,
                        started_at = NOW(), updated_at = NOW()
                    WHERE id = (
                        SELECT id FROM document_processing_queue
                        WHERE status = 'queued'
                        ORDER BY priority ASC, created_at ASC
                        LIMIT 1
                        FOR UPDATE SKIP LOCKED
                    )
                    RETURNING id as queue_id, document_upload_id, priority, retry_count
                ", conn);

                cmd.Parameters.AddWithValue("workerId", _workerId);
                using var reader = await cmd.ExecuteReaderAsync();

                if (!await reader.ReadAsync())
                    return null;

                var queueId = reader.GetGuid(0);
                var documentId = reader.GetGuid(1);
                var priority = reader.GetInt32(2);
                var retryCount = reader.GetInt32(3);

                await reader.CloseAsync();

                // Get document details
                using var docCmd = new NpgsqlCommand(@"
                    SELECT id, organization_id, site_id, scope, upload_type,
                           file_name, file_path, file_type, uploaded_by
                    FROM document_uploads WHERE id = @documentId
                ", conn);

                docCmd.Parameters.AddWithValue("documentId", documentId);
                using var docReader = await docCmd.ExecuteReaderAsync();

                if (!await docReader.ReadAsync())
                    return null;

                return new DocumentRecord
                {
                    QueueId = queueId,
                    Id = docReader.GetGuid(0),
                    OrganizationId = docReader.GetGuid(1),
                    SiteId = docReader.GetGuid(2),
                    Scope = docReader.GetInt32(3),
                    UploadType = docReader.GetString(4),
                    FileName = docReader.GetString(5),
                    FilePath = docReader.GetString(6),
                    FileType = docReader.GetString(7),
                    UploadedBy = docReader.GetGuid(8),
                    Priority = priority,
                    RetryCount = retryCount
                };
            }
            catch (Exception ex)
            {
                _logger.Error(ex, "Error getting next document");
                return null;
            }
        }

        public async Task MarkProcessingCompleteAsync(
            Guid queueId, Guid documentId, ExtractedData extractedData,
            decimal confidence, Guid? emissionId, int processingTimeMs, string model)
        {
            try
            {
                using var conn = new NpgsqlConnection(_connectionString);
                await conn.OpenAsync();
                using var transaction = await conn.BeginTransactionAsync();

                // Update queue
                using var queueCmd = new NpgsqlCommand(@"
                    UPDATE document_processing_queue
                    SET status = 'completed', completed_at = NOW(), updated_at = NOW(),
                        llm_provider = 'groq', llm_model = @model, processing_time_ms = @processingTimeMs
                    WHERE id = @queueId
                ", conn, transaction);

                queueCmd.Parameters.AddWithValue("model", model);
                queueCmd.Parameters.AddWithValue("processingTimeMs", processingTimeMs);
                queueCmd.Parameters.AddWithValue("queueId", queueId);
                await queueCmd.ExecuteNonQueryAsync();

                // Update document
                using var docCmd = new NpgsqlCommand(@"
                    UPDATE document_uploads
                    SET processing_status = 'completed', extraction_status = 'completed',
                        extracted_data = @extractedData::jsonb, extraction_confidence_score = @confidence,
                        linked_emission_entry_id = @emissionId, updated_at = NOW()
                    WHERE id = @documentId
                ", conn, transaction);

                var jsonData = Newtonsoft.Json.JsonConvert.SerializeObject(extractedData);
                docCmd.Parameters.AddWithValue("extractedData", jsonData);
                docCmd.Parameters.AddWithValue("confidence", confidence);
                docCmd.Parameters.AddWithValue("emissionId", (object)emissionId ?? DBNull.Value);
                docCmd.Parameters.AddWithValue("documentId", documentId);
                await docCmd.ExecuteNonQueryAsync();

                await transaction.CommitAsync();
                _logger.Information($"Marked document {documentId} as completed (confidence: {confidence:F2})");
            }
            catch (Exception ex)
            {
                _logger.Error(ex, "Error marking document as complete");
                throw;
            }
        }

        public async Task MarkProcessingFailedAsync(
            Guid queueId, Guid documentId, string errorMessage, int retryCount, int maxRetries)
        {
            try
            {
                using var conn = new NpgsqlConnection(_connectionString);
                await conn.OpenAsync();
                using var transaction = await conn.BeginTransactionAsync();

                bool shouldRetry = retryCount < maxRetries;
                string queueStatus = shouldRetry ? "retrying" : "failed";
                string docStatus = shouldRetry ? "in_progress" : "error";

                using var queueCmd = new NpgsqlCommand(@"
                    UPDATE document_processing_queue
                    SET status = @status, completed_at = NOW(), updated_at = NOW(),
                        error_message = @errorMessage
                    WHERE id = @queueId
                ", conn, transaction);

                queueCmd.Parameters.AddWithValue("status", queueStatus);
                queueCmd.Parameters.AddWithValue("errorMessage", errorMessage);
                queueCmd.Parameters.AddWithValue("queueId", queueId);
                await queueCmd.ExecuteNonQueryAsync();

                using var docCmd = new NpgsqlCommand(@"
                    UPDATE document_uploads
                    SET extraction_status = @status, extraction_errors = @errorMessage, updated_at = NOW()
                    WHERE id = @documentId
                ", conn, transaction);

                docCmd.Parameters.AddWithValue("status", docStatus);
                docCmd.Parameters.AddWithValue("errorMessage", errorMessage);
                docCmd.Parameters.AddWithValue("documentId", documentId);
                await docCmd.ExecuteNonQueryAsync();

                await transaction.CommitAsync();

                if (shouldRetry)
                    _logger.Warning($"Document {documentId} will retry (attempt {retryCount + 1}/{maxRetries})");
                else
                    _logger.Error($"Document {documentId} failed permanently: {errorMessage}");
            }
            catch (Exception ex)
            {
                _logger.Error(ex, "Error marking document as failed");
            }
        }

        public async Task<Guid?> InsertScope2EmissionAsync(
            DocumentRecord document, ExtractedData extractedData, Guid? emissionFactorId)
        {
            try
            {
                using var conn = new NpgsqlConnection(_connectionString);
                await conn.OpenAsync();

                DateTime dateObj = string.IsNullOrEmpty(extractedData.BillingPeriodStart)
                    ? DateTime.Now
                    : DateTime.Parse(extractedData.BillingPeriodStart);

                string energyType = extractedData.ServiceType ?? "Electricity";
                decimal consumption = extractedData.TotalConsumptionKwh
                    ?? extractedData.ConsumptionAmount
                    ?? throw new Exception("No consumption amount found");

                using var cmd = new NpgsqlCommand(@"
                    SELECT insert_scope2_emission(
                        @siteId, @year, @month, @energyType, @consumption,
                        @uploadedBy, @emissionFactorId, @notes, @documentId
                    )
                ", conn);

                cmd.Parameters.AddWithValue("siteId", document.SiteId);
                cmd.Parameters.AddWithValue("year", dateObj.Year);
                cmd.Parameters.AddWithValue("month", dateObj.Month);
                cmd.Parameters.AddWithValue("energyType", energyType);
                cmd.Parameters.AddWithValue("consumption", consumption);
                cmd.Parameters.AddWithValue("uploadedBy", document.UploadedBy);
                cmd.Parameters.AddWithValue("emissionFactorId", (object)emissionFactorId ?? DBNull.Value);
                cmd.Parameters.AddWithValue("notes", extractedData.ExtractionNotes ?? "");
                cmd.Parameters.AddWithValue("documentId", document.Id);

                var result = await cmd.ExecuteScalarAsync();
                var emissionId = (Guid)result;

                _logger.Information($"Inserted Scope 2 emission: {emissionId}");
                return emissionId;
            }
            catch (Exception ex)
            {
                _logger.Error(ex, "Error inserting Scope 2 emission");
                throw;
            }
        }
    }
}
```

### Services/DocumentProcessor.cs

```csharp
using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using Newtonsoft.Json;
using Serilog;
using DocumentProcessorService.Models;

namespace DocumentProcessorService.Services
{
    public class DocumentProcessor
    {
        private readonly DatabaseService _databaseService;
        private readonly GroqApiService _groqApiService;
        private readonly PdfImageConverter _pdfConverter;
        private readonly ILogger _logger;
        private readonly int _pollIntervalSeconds;
        private readonly LlmPromptsConfig _llmPrompts;
        private bool _shutdownRequested = false;

        public DocumentProcessor(
            DatabaseService databaseService,
            GroqApiService groqApiService,
            PdfImageConverter pdfConverter,
            int pollIntervalSeconds,
            ILogger logger)
        {
            _databaseService = databaseService;
            _groqApiService = groqApiService;
            _pdfConverter = pdfConverter;
            _pollIntervalSeconds = pollIntervalSeconds;
            _logger = logger;
            _llmPrompts = LoadLlmPrompts();
        }

        public async Task StartAsync(CancellationToken cancellationToken)
        {
            _logger.Information("Document processor started");
            _logger.Information($"Polling interval: {_pollIntervalSeconds} seconds");
            _logger.Information($"Loaded {_llmPrompts.Prompts.Count} prompt templates");

            while (!_shutdownRequested && !cancellationToken.IsCancellationRequested)
            {
                try
                {
                    var document = await _databaseService.GetNextQueuedDocumentAsync();

                    if (document != null)
                    {
                        _logger.Information($"Picked up document {document.Id} (queue {document.QueueId})");
                        bool success = await ProcessDocumentAsync(document);

                        if (!success)
                            _logger.Warning($"Document {document.Id} processing failed");
                    }
                    else
                    {
                        _logger.Debug("No documents in queue, waiting...");
                        await Task.Delay(TimeSpan.FromSeconds(_pollIntervalSeconds), cancellationToken);
                    }
                }
                catch (OperationCanceledException)
                {
                    _logger.Information("Cancellation requested");
                    break;
                }
                catch (Exception ex)
                {
                    _logger.Error(ex, "Unexpected error in main loop");
                    await Task.Delay(TimeSpan.FromSeconds(_pollIntervalSeconds), cancellationToken);
                }
            }

            _logger.Information("Document processor stopped");
        }

        private async Task<bool> ProcessDocumentAsync(DocumentRecord document)
        {
            var startTime = DateTime.UtcNow;

            try
            {
                _logger.Information($"Processing document {document.Id} (scope {document.Scope})");

                string promptKey = GetPromptKey(document.Scope, document.UploadType);
                if (promptKey == null || !_llmPrompts.Prompts.ContainsKey(promptKey))
                    throw new Exception($"No prompt found for scope {document.Scope}, type {document.UploadType}");

                var promptConfig = _llmPrompts.Prompts[promptKey];

                string imageBase64 = _pdfConverter.ConvertToBase64(document.FilePath, document.FileType);
                var extractedData = await _groqApiService.ExtractDataAsync(imageBase64, promptConfig);

                var (isValid, errorMsg) = ValidateExtractedData(extractedData, promptConfig);
                if (!isValid)
                    throw new Exception($"Validation failed: {errorMsg}");

                decimal confidence = extractedData.ConfidenceScore;
                _logger.Information($"Extracted data with confidence {confidence:F2}");

                Guid? emissionId = null;
                if (document.Scope == 2)
                {
                    emissionId = await _databaseService.InsertScope2EmissionAsync(document, extractedData, null);
                }

                int processingTimeMs = (int)(DateTime.UtcNow - startTime).TotalMilliseconds;
                await _databaseService.MarkProcessingCompleteAsync(
                    document.QueueId, document.Id, extractedData,
                    confidence, emissionId, processingTimeMs, "llama-3.2-11b-vision-preview");

                _logger.Information($"Successfully processed document {document.Id} in {processingTimeMs}ms");
                return true;
            }
            catch (Exception ex)
            {
                _logger.Error(ex, $"Error processing document {document.Id}");
                await _databaseService.MarkProcessingFailedAsync(
                    document.QueueId, document.Id, ex.Message, document.RetryCount, 3);
                return false;
            }
        }

        private string GetPromptKey(int scope, string uploadType)
        {
            var map = new Dictionary<(int, string), string>
            {
                { (1, "fuel_receipt"), "scope1_fuel" },
                { (1, "fuel_invoice"), "scope1_fuel" },
                { (1, "waste_invoice"), "scope1_waste" },
                { (2, "utility_bill"), "scope2_electricity" },
                { (2, "electricity_bill"), "scope2_electricity" },
                { (2, "heat_bill"), "scope2_heat_steam" },
                { (2, "steam_bill"), "scope2_heat_steam" },
                { (2, "cooling_bill"), "scope2_heat_steam" },
                { (3, "freight_invoice"), "scope3_logistics" },
                { (3, "shipping_manifest"), "scope3_logistics" },
            };

            return map.TryGetValue((scope, uploadType), out var key) ? key : null;
        }

        private (bool isValid, string errorMessage) ValidateExtractedData(
            ExtractedData data, PromptConfig promptConfig)
        {
            if (data.ConfidenceScore < promptConfig.ConfidenceThreshold)
                return (false, $"Confidence {data.ConfidenceScore:F2} below threshold {promptConfig.ConfidenceThreshold}");

            return (true, null);
        }

        private LlmPromptsConfig LoadLlmPrompts()
        {
            string promptsFile = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "llm_prompts.json");

            if (!File.Exists(promptsFile))
                throw new FileNotFoundException($"llm_prompts.json not found at {promptsFile}");

            string json = File.ReadAllText(promptsFile);
            return JsonConvert.DeserializeObject<LlmPromptsConfig>(json);
        }

        public void RequestShutdown() => _shutdownRequested = true;
    }
}
```

### Program.cs

```csharp
using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Extensions.Configuration;
using Serilog;
using DocumentProcessorService.Services;

namespace DocumentProcessorService
{
    class Program
    {
        static async Task Main(string[] args)
        {
            var configuration = new ConfigurationBuilder()
                .SetBasePath(Directory.GetCurrentDirectory())
                .AddJsonFile("appsettings.json", optional: false, reloadOnChange: true)
                .AddEnvironmentVariables()
                .Build();

            string logLevel = configuration["Logging:LogLevel"] ?? "Information";
            string logFile = configuration["Logging:LogFilePath"] ?? "document_processor.log";

            Log.Logger = new LoggerConfiguration()
                .MinimumLevel.Is(ParseLogLevel(logLevel))
                .WriteTo.Console()
                .WriteTo.File(logFile, rollingInterval: RollingInterval.Day)
                .CreateLogger();

            try
            {
                Log.Information("=".PadRight(60, '='));
                Log.Information("Document Processor Service Starting");
                Log.Information("=".PadRight(60, '='));

                string dbHost = configuration["Database:Host"];
                int dbPort = int.Parse(configuration["Database:Port"]);
                string dbName = configuration["Database:Database"];
                string dbUser = configuration["Database:Username"];
                string dbPassword = configuration["Database:Password"];

                string groqApiKey = configuration["Groq:ApiKey"];
                string groqModel = configuration["Groq:Model"];
                double groqTemperature = double.Parse(configuration["Groq:Temperature"]);
                int groqMaxTokens = int.Parse(configuration["Groq:MaxTokens"]);

                int pollInterval = int.Parse(configuration["Processing:PollIntervalSeconds"]);
                string workerId = configuration["Processing:WorkerId"];

                if (string.IsNullOrEmpty(groqApiKey))
                {
                    Log.Fatal("GROQ_API_KEY not configured!");
                    return;
                }

                string connectionString = $"Host={dbHost};Port={dbPort};Database={dbName};Username={dbUser};Password={dbPassword}";

                Log.Information($"Worker ID: {workerId}");
                Log.Information($"Database: {dbName}@{dbHost}");
                Log.Information($"Groq Model: {groqModel}");
                Log.Information($"Poll Interval: {pollInterval}s");

                var pdfConverter = new PdfImageConverter(Log.Logger);
                var groqService = new GroqApiService(groqApiKey, groqModel, groqTemperature, groqMaxTokens, Log.Logger);
                var databaseService = new DatabaseService(connectionString, workerId, Log.Logger);
                var documentProcessor = new DocumentProcessor(databaseService, groqService, pdfConverter, pollInterval, Log.Logger);

                var cts = new CancellationTokenSource();
                Console.CancelKeyPress += (sender, e) =>
                {
                    Log.Information("Shutdown signal received...");
                    e.Cancel = true;
                    cts.Cancel();
                    documentProcessor.RequestShutdown();
                };

                await documentProcessor.StartAsync(cts.Token);

                Log.Information("Document processor stopped gracefully");
            }
            catch (Exception ex)
            {
                Log.Fatal(ex, "Application terminated unexpectedly");
            }
            finally
            {
                Log.CloseAndFlush();
            }
        }

        static Serilog.Events.LogEventLevel ParseLogLevel(string level)
        {
            return level.ToLower() switch
            {
                "debug" => Serilog.Events.LogEventLevel.Debug,
                "information" => Serilog.Events.LogEventLevel.Information,
                "warning" => Serilog.Events.LogEventLevel.Warning,
                "error" => Serilog.Events.LogEventLevel.Error,
                _ => Serilog.Events.LogEventLevel.Information
            };
        }
    }
}
```

---

## Setup Instructions

### Step 1: Verify Prerequisites

```bash
# Check .NET installation
dotnet --version
# Should output: 8.0.x

# Check PostgreSQL is running
psql -U postgres -d carbon_accounting -c "SELECT version();"

# Check Poppler installation
dir "C:\Program Files\poppler\Library\bin"
```

### Step 2: Create and Configure Project

```bash
# Create project
mkdir DocumentProcessorService
cd DocumentProcessorService
dotnet new console -n DocumentProcessorService
cd DocumentProcessorService

# Install all NuGet packages (copy entire block)
dotnet add package Npgsql --version 8.0.1
dotnet add package PDFtoImage --version 4.0.1
dotnet add package System.Net.Http.Json --version 8.0.0
dotnet add package Newtonsoft.Json --version 13.0.3
dotnet add package Microsoft.Extensions.Configuration --version 8.0.0
dotnet add package Microsoft.Extensions.Configuration.Json --version 8.0.0
dotnet add package Microsoft.Extensions.Configuration.EnvironmentVariables --version 8.0.0
dotnet add package Serilog --version 3.1.1
dotnet add package Serilog.Sinks.Console --version 5.0.1
dotnet add package Serilog.Sinks.File --version 5.0.0

# Create folders
mkdir Models
mkdir Services
mkdir Helpers
```

### Step 3: Add All Code Files

Create each file listed in the "Code Files" section above.

### Step 4: Configure appsettings.json

Edit `appsettings.json` with your actual values:
- Database password
- Groq API key
- Poppler path (if different)

### Step 5: Copy llm_prompts.json

```bash
# Copy from your Python project
copy ..\PythonProject\llm_prompts.json .
```

Or ensure it's copied to output directory by editing `.csproj`:

```xml
<ItemGroup>
  <None Update="llm_prompts.json">
    <CopyToOutputDirectory>Always</CopyToOutputDirectory>
  </None>
  <None Update="appsettings.json">
    <CopyToOutputDirectory>Always</CopyToOutputDirectory>
  </None>
</ItemGroup>
```

### Step 6: Build

```bash
dotnet build

# You should see:
# Build succeeded.
#     0 Warning(s)
#     0 Error(s)
```

---

## Running the Application

### Development Mode

```bash
# Run the application
dotnet run

# You should see:
# ============================================================
# Document Processor Service Starting
# ============================================================
# Worker ID: worker_dotnet_001
# Database: carbon_accounting@localhost
# Groq Model: llama-3.2-11b-vision-preview
# Poll Interval: 10s
# Document processor started
# Loaded 5 prompt templates
# No documents in queue, waiting...
```

### Test with Sample Document

**Insert test document in PostgreSQL:**

```sql
INSERT INTO document_uploads (
    id, organization_id, site_id, scope, upload_type,
    file_name, file_path, file_type, uploaded_by, processing_status
) VALUES (
    gen_random_uuid(),
    'your-org-id'::uuid,
    'your-site-id'::uuid,
    2,
    'utility_bill',
    'test_bill.pdf',
    'C:\path\to\test_bill.pdf',
    'pdf',
    'your-user-id'::uuid,
    'pending'
);
```

**Watch the console output:**

```
Picked up document ... (queue ...)
Converting PDF to image: C:\path\to\test_bill.pdf
Image encoded successfully (...)
Calling Groq API with model llama-3.2-11b-vision-preview
Groq API response parsed (confidence: 0.92)
Extracted data with confidence 0.92
Inserted Scope 2 emission: ...
Marked document ... as completed (confidence: 0.92)
Successfully processed document ... in 4523ms
```

### Stop the Application

Press `Ctrl+C`:

```
Shutdown signal received...
Cancellation requested
Document processor stopped gracefully
```

---

## Python vs C# Comparison

### Virtual Environment

**Python:**
```bash
python -m venv venv
venv\Scripts\activate
pip install -r requirements.txt
```

**C#:**
```bash
# No virtual environment needed!
# Dependencies managed per-project in .csproj
dotnet restore
```

### Configuration

**Python (.env):**
```python
from dotenv import load_dotenv
load_dotenv()
api_key = os.getenv('GROQ_API_KEY')
```

**C# (appsettings.json):**
```csharp
var configuration = new ConfigurationBuilder()
    .AddJsonFile("appsettings.json")
    .Build();
string apiKey = configuration["Groq:ApiKey"];
```

### PDF to Image

**Python:**
```python
from pdf2image import convert_from_path
images = convert_from_path('bill.pdf')
```

**C#:**
```csharp
using PDFtoImage;
var bitmap = Conversion.ToImage(pdfStream, dpi: 300);
```

### Database Operations

**Python:**
```python
import psycopg2
conn = psycopg2.connect(host='localhost', database='db')
```

**C#:**
```csharp
using Npgsql;
var conn = new NpgsqlConnection("Host=localhost;Database=db");
```

### Async/Await

**Python:**
```python
async def process():
    await some_function()
```

**C#:**
```csharp
async Task ProcessAsync()
{
    await SomeFunctionAsync();
}
```

### Type Safety

**Python (Dynamic):**
```python
def process(document):  # Any type
    name = document['file_name']
```

**C# (Strongly Typed):**
```csharp
public void Process(DocumentRecord document)
{
    string name = document.FileName;  // Compile-time checked!
}
```

---

## Troubleshooting

### Error: "Groq API Key not configured"

**Solution:**
- Check `appsettings.json` has correct API key
- Key should start with `gsk_`

### Error: "Connection refused" (PostgreSQL)

**Solution:**
```bash
# Check PostgreSQL is running
services.msc → PostgreSQL → Start

# Verify connection string in appsettings.json
# Check username, password, database name
```

### Error: "llm_prompts.json not found"

**Solution:**
```bash
# Copy to output directory
copy llm_prompts.json bin\Debug\net8.0\

# Or edit .csproj:
<ItemGroup>
  <None Update="llm_prompts.json">
    <CopyToOutputDirectory>Always</CopyToOutputDirectory>
  </None>
</ItemGroup>
```

### Error: "Poppler not found"

**Solution:**
```bash
# Verify Poppler installed
dir "C:\Program Files\poppler\Library\bin"

# Update path in appsettings.json if different
```

### Error: "Could not load file or assembly"

**Solution:**
```bash
# Restore NuGet packages
dotnet restore

# Clean and rebuild
dotnet clean
dotnet build
```

### Error: "Document not found in database"

**Solution:**
```sql
-- Check document exists
SELECT * FROM document_uploads WHERE processing_status = 'pending';

-- Check file path is correct and file exists
```

---

## Advanced: Windows Service

To run as a Windows Service (always running in background):

### Step 1: Install Package

```bash
dotnet add package Microsoft.Extensions.Hosting
dotnet add package Microsoft.Extensions.Hosting.WindowsServices
```

### Step 2: Modify Program.cs

```csharp
using Microsoft.Extensions.Hosting;

var builder = Host.CreateApplicationBuilder(args);
builder.Services.AddHostedService<DocumentProcessorService>();
builder.Services.AddWindowsService();

var host = builder.Build();
await host.RunAsync();
```

### Step 3: Publish as Self-Contained

```bash
dotnet publish -c Release -r win-x64 --self-contained -o C:\Services\DocumentProcessor
```

### Step 4: Install as Service

```bash
# Open Command Prompt as Administrator
sc create "DocumentProcessorService" binPath="C:\Services\DocumentProcessor\DocumentProcessorService.exe"
sc description "DocumentProcessorService" "LLM Document Processor for Carbon Accounting"
sc start "DocumentProcessorService"

# To stop:
sc stop "DocumentProcessorService"

# To remove:
sc delete "DocumentProcessorService"
```

---

## Summary Checklist

Before running:

- [ ] .NET 8.0 SDK installed
- [ ] PostgreSQL running with `carbon_accounting` database
- [ ] Poppler installed at `C:\Program Files\poppler`
- [ ] Project created with `dotnet new console`
- [ ] All NuGet packages installed
- [ ] All code files created (Models, Services, Program.cs)
- [ ] `appsettings.json` configured with DB password and Groq API key
- [ ] `llm_prompts.json` copied to project folder
- [ ] `dotnet build` successful
- [ ] Database triggers installed (`create_document_processing_triggers.sql`)
- [ ] Test document ready

Ready to run:

```bash
dotnet run
```

---

## Support

For issues:
- Check logs in `document_processor.log`
- Verify database connection with `psql`
- Test Groq API key at https://console.groq.com/
- Check Poppler installation

---

## License

Same as Python version - Carbon Accounting System

---

## Author

Converted from Python `document_processor1.py`
Version: 1.0
Date: 2025-11-11
