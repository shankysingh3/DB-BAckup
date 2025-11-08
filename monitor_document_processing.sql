-- ================================================================================
-- Document Processing Monitoring Queries
-- ================================================================================
-- Purpose: Dashboard and monitoring queries for document processing system
-- Created: 2025-11-08
-- ================================================================================

-- ================================================================================
-- QUERY 1: Queue Status Overview
-- ================================================================================

SELECT
    'Queue Status Overview' AS report_title,
    NOW() AS report_timestamp;

SELECT
    status,
    COUNT(*) AS count,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS percentage
FROM document_processing_queue
GROUP BY status
ORDER BY
    CASE status
        WHEN 'processing' THEN 1
        WHEN 'queued' THEN 2
        WHEN 'completed' THEN 3
        WHEN 'failed' THEN 4
        WHEN 'retrying' THEN 5
    END;


-- ================================================================================
-- QUERY 2: Processing Performance by Scope
-- ================================================================================

SELECT
    'Processing Performance by Scope' AS report_title;

SELECT
    du.scope,
    COUNT(*) AS total_documents,
    SUM(CASE WHEN dpq.status = 'completed' THEN 1 ELSE 0 END) AS completed,
    SUM(CASE WHEN dpq.status = 'failed' THEN 1 ELSE 0 END) AS failed,
    ROUND(100.0 * SUM(CASE WHEN dpq.status = 'completed' THEN 1 ELSE 0 END) / COUNT(*), 2) AS success_rate_pct,
    ROUND(AVG(CASE WHEN dpq.status = 'completed' THEN dpq.processing_time_ms END), 0) AS avg_processing_time_ms
FROM document_uploads du
JOIN document_processing_queue dpq ON dpq.document_upload_id = du.id
GROUP BY du.scope
ORDER BY du.scope;


-- ================================================================================
-- QUERY 3: Recent Processing Activity (Last 24 hours)
-- ================================================================================

SELECT
    'Recent Processing Activity (24h)' AS report_title;

SELECT
    DATE_TRUNC('hour', dpq.created_at) AS hour,
    COUNT(*) AS documents_queued,
    SUM(CASE WHEN dpq.status = 'completed' THEN 1 ELSE 0 END) AS completed,
    SUM(CASE WHEN dpq.status = 'failed' THEN 1 ELSE 0 END) AS failed
FROM document_processing_queue dpq
WHERE dpq.created_at >= NOW() - INTERVAL '24 hours'
GROUP BY DATE_TRUNC('hour', dpq.created_at)
ORDER BY hour DESC;


-- ================================================================================
-- QUERY 4: Failed Documents with Errors
-- ================================================================================

SELECT
    'Failed Documents (Troubleshooting)' AS report_title;

SELECT
    du.id AS document_id,
    du.file_name,
    du.scope,
    du.upload_type,
    dpq.error_message,
    dpq.retry_count,
    dpq.max_retries,
    dpq.completed_at AS failed_at
FROM document_uploads du
JOIN document_processing_queue dpq ON dpq.document_upload_id = du.id
WHERE dpq.status = 'failed'
ORDER BY dpq.completed_at DESC
LIMIT 20;


-- ================================================================================
-- QUERY 5: Extraction Confidence Score Analysis
-- ================================================================================

SELECT
    'Extraction Confidence Analysis' AS report_title;

SELECT
    CASE
        WHEN extraction_confidence_score >= 0.9 THEN 'Very High (0.9-1.0)'
        WHEN extraction_confidence_score >= 0.8 THEN 'High (0.8-0.9)'
        WHEN extraction_confidence_score >= 0.7 THEN 'Medium (0.7-0.8)'
        WHEN extraction_confidence_score >= 0.6 THEN 'Low (0.6-0.7)'
        ELSE 'Very Low (<0.6)'
    END AS confidence_range,
    COUNT(*) AS document_count,
    ROUND(AVG(extraction_confidence_score), 3) AS avg_score
FROM document_uploads
WHERE extraction_status = 'completed'
  AND extraction_confidence_score IS NOT NULL
GROUP BY
    CASE
        WHEN extraction_confidence_score >= 0.9 THEN 'Very High (0.9-1.0)'
        WHEN extraction_confidence_score >= 0.8 THEN 'High (0.8-0.9)'
        WHEN extraction_confidence_score >= 0.7 THEN 'Medium (0.7-0.8)'
        WHEN extraction_confidence_score >= 0.6 THEN 'Low (0.6-0.7)'
        ELSE 'Very Low (<0.6)'
    END
ORDER BY avg_score DESC;


-- ================================================================================
-- QUERY 6: Documents with Low Confidence (Manual Review Queue)
-- ================================================================================

SELECT
    'Low Confidence Documents (Manual Review Required)' AS report_title;

SELECT
    du.id,
    du.file_name,
    du.scope,
    du.extraction_confidence_score,
    du.linked_emission_entry_id,
    du.uploaded_at
FROM document_uploads du
WHERE du.extraction_status = 'completed'
  AND du.extraction_confidence_score < 0.7
ORDER BY du.extraction_confidence_score ASC, du.uploaded_at DESC
LIMIT 50;


-- ================================================================================
-- QUERY 7: Processing Queue Backlog
-- ================================================================================

SELECT
    'Current Processing Queue Backlog' AS report_title;

SELECT
    dpq.id AS queue_id,
    du.file_name,
    du.scope,
    dpq.status,
    dpq.priority,
    dpq.retry_count,
    EXTRACT(EPOCH FROM (NOW() - dpq.created_at)) / 60 AS minutes_waiting,
    dpq.created_at
FROM document_processing_queue dpq
JOIN document_uploads du ON dpq.document_upload_id = du.id
WHERE dpq.status IN ('queued', 'processing', 'retrying')
ORDER BY dpq.priority ASC, dpq.created_at ASC;


-- ================================================================================
-- QUERY 8: Worker Performance (Multi-Worker Tracking)
-- ================================================================================

SELECT
    'Worker Performance' AS report_title;

SELECT
    COALESCE(dpq.worker_id, 'No Worker Assigned') AS worker_id,
    COUNT(*) AS documents_processed,
    SUM(CASE WHEN dpq.status = 'completed' THEN 1 ELSE 0 END) AS successful,
    SUM(CASE WHEN dpq.status = 'failed' THEN 1 ELSE 0 END) AS failed,
    ROUND(AVG(dpq.processing_time_ms), 0) AS avg_processing_time_ms,
    MAX(dpq.completed_at) AS last_active
FROM document_processing_queue dpq
WHERE dpq.worker_id IS NOT NULL
GROUP BY dpq.worker_id
ORDER BY documents_processed DESC;


-- ================================================================================
-- QUERY 9: LLM Provider/Model Statistics
-- ================================================================================

SELECT
    'LLM Provider/Model Usage' AS report_title;

SELECT
    COALESCE(dpq.llm_provider, 'Unknown') AS llm_provider,
    COALESCE(dpq.llm_model, 'Unknown') AS llm_model,
    COUNT(*) AS requests,
    ROUND(AVG(dpq.processing_time_ms), 0) AS avg_time_ms,
    SUM(CASE WHEN dpq.status = 'completed' THEN 1 ELSE 0 END) AS successful
FROM document_processing_queue dpq
WHERE dpq.llm_provider IS NOT NULL
GROUP BY dpq.llm_provider, dpq.llm_model
ORDER BY requests DESC;


-- ================================================================================
-- QUERY 10: Document-to-Emission Linkage Success Rate
-- ================================================================================

SELECT
    'Document-to-Emission Linkage' AS report_title;

SELECT
    du.scope,
    COUNT(*) AS total_completed_documents,
    SUM(CASE WHEN du.linked_emission_entry_id IS NOT NULL THEN 1 ELSE 0 END) AS linked_to_emission,
    SUM(CASE WHEN du.linked_emission_entry_id IS NULL THEN 1 ELSE 0 END) AS not_linked,
    ROUND(100.0 * SUM(CASE WHEN du.linked_emission_entry_id IS NOT NULL THEN 1 ELSE 0 END) / COUNT(*), 2) AS link_success_rate_pct
FROM document_uploads du
WHERE du.extraction_status = 'completed'
GROUP BY du.scope
ORDER BY du.scope;


-- ================================================================================
-- QUERY 11: Extracted Data Sample (JSON Inspection)
-- ================================================================================

SELECT
    'Sample Extracted Data (JSON)' AS report_title;

SELECT
    du.id,
    du.file_name,
    du.scope,
    du.extraction_confidence_score,
    du.extracted_data
FROM document_uploads du
WHERE du.extraction_status = 'completed'
  AND du.extracted_data IS NOT NULL
ORDER BY du.uploaded_at DESC
LIMIT 10;


-- ================================================================================
-- QUERY 12: Retry Analysis
-- ================================================================================

SELECT
    'Retry Analysis' AS report_title;

SELECT
    dpq.retry_count,
    COUNT(*) AS document_count,
    AVG(dpq.processing_time_ms) AS avg_time_ms
FROM document_processing_queue dpq
WHERE dpq.status IN ('completed', 'failed')
GROUP BY dpq.retry_count
ORDER BY dpq.retry_count;


-- ================================================================================
-- QUERY 13: Hourly Processing Throughput
-- ================================================================================

SELECT
    'Hourly Processing Throughput' AS report_title;

SELECT
    DATE_TRUNC('hour', dpq.completed_at) AS hour,
    COUNT(*) AS documents_processed,
    ROUND(AVG(dpq.processing_time_ms), 0) AS avg_time_ms
FROM document_processing_queue dpq
WHERE dpq.status = 'completed'
  AND dpq.completed_at >= NOW() - INTERVAL '24 hours'
GROUP BY DATE_TRUNC('hour', dpq.completed_at)
ORDER BY hour DESC;


-- ================================================================================
-- QUERY 14: Documents Pending Manual Review
-- ================================================================================

CREATE OR REPLACE VIEW pending_manual_review AS
SELECT
    du.id,
    du.file_name,
    du.scope,
    du.upload_type,
    du.extraction_confidence_score,
    du.extracted_data,
    du.uploaded_at,
    'Low confidence score' AS review_reason
FROM document_uploads du
WHERE du.extraction_status = 'completed'
  AND du.extraction_confidence_score < 0.7
  AND du.linked_emission_entry_id IS NULL

UNION ALL

SELECT
    du.id,
    du.file_name,
    du.scope,
    du.upload_type,
    du.extraction_confidence_score,
    du.extracted_data,
    du.uploaded_at,
    'No emission link' AS review_reason
FROM document_uploads du
WHERE du.extraction_status = 'completed'
  AND du.extraction_confidence_score >= 0.7
  AND du.linked_emission_entry_id IS NULL

ORDER BY uploaded_at DESC;

COMMENT ON VIEW pending_manual_review IS
'Documents that require manual review due to low confidence or missing emission linkage';


-- ================================================================================
-- QUERY 15: Active Workers (Currently Processing)
-- ================================================================================

SELECT
    'Currently Active Workers' AS report_title;

SELECT
    dpq.worker_id,
    du.file_name,
    du.scope,
    dpq.priority,
    EXTRACT(EPOCH FROM (NOW() - dpq.started_at)) / 60 AS minutes_processing,
    dpq.started_at
FROM document_processing_queue dpq
JOIN document_uploads du ON dpq.document_upload_id = du.id
WHERE dpq.status = 'processing'
ORDER BY dpq.started_at;


-- ================================================================================
-- ALERTING QUERIES (For Monitoring Systems)
-- ================================================================================

-- Alert 1: Stalled Documents (processing > 10 minutes)
SELECT
    'ALERT: Stalled Documents' AS alert_type,
    COUNT(*) AS stalled_count
FROM document_processing_queue
WHERE status = 'processing'
  AND started_at < NOW() - INTERVAL '10 minutes';


-- Alert 2: Large Backlog (> 100 documents queued)
SELECT
    'ALERT: Large Backlog' AS alert_type,
    COUNT(*) AS queued_count
FROM document_processing_queue
WHERE status = 'queued'
HAVING COUNT(*) > 100;


-- Alert 3: High Failure Rate (> 20% in last hour)
SELECT
    'ALERT: High Failure Rate' AS alert_type,
    ROUND(100.0 * SUM(CASE WHEN status = 'failed' THEN 1 ELSE 0 END) / COUNT(*), 2) AS failure_rate_pct
FROM document_processing_queue
WHERE completed_at >= NOW() - INTERVAL '1 hour'
HAVING ROUND(100.0 * SUM(CASE WHEN status = 'failed' THEN 1 ELSE 0 END) / COUNT(*), 2) > 20;


-- ================================================================================
-- HELPER FUNCTION: Quick Dashboard
-- ================================================================================

CREATE OR REPLACE FUNCTION get_processing_dashboard()
RETURNS TABLE(
    metric VARCHAR,
    value TEXT
) AS $$
BEGIN
    RETURN QUERY

    -- Total documents
    SELECT 'total_documents'::VARCHAR,
           COUNT(*)::TEXT
    FROM document_uploads

    UNION ALL

    -- Queued
    SELECT 'queued'::VARCHAR,
           COUNT(*)::TEXT
    FROM document_processing_queue
    WHERE status = 'queued'

    UNION ALL

    -- Processing
    SELECT 'processing'::VARCHAR,
           COUNT(*)::TEXT
    FROM document_processing_queue
    WHERE status = 'processing'

    UNION ALL

    -- Completed (24h)
    SELECT 'completed_24h'::VARCHAR,
           COUNT(*)::TEXT
    FROM document_processing_queue
    WHERE status = 'completed'
      AND completed_at >= NOW() - INTERVAL '24 hours'

    UNION ALL

    -- Failed (24h)
    SELECT 'failed_24h'::VARCHAR,
           COUNT(*)::TEXT
    FROM document_processing_queue
    WHERE status = 'failed'
      AND completed_at >= NOW() - INTERVAL '24 hours'

    UNION ALL

    -- Avg processing time (24h)
    SELECT 'avg_time_ms_24h'::VARCHAR,
           COALESCE(ROUND(AVG(processing_time_ms))::TEXT, '0')
    FROM document_processing_queue
    WHERE status = 'completed'
      AND completed_at >= NOW() - INTERVAL '24 hours'

    UNION ALL

    -- Success rate (24h)
    SELECT 'success_rate_24h_pct'::VARCHAR,
           COALESCE(
               ROUND(
                   100.0 * SUM(CASE WHEN status = 'completed' THEN 1 ELSE 0 END)::NUMERIC /
                   NULLIF(COUNT(*), 0),
                   2
               )::TEXT,
               '0'
           )
    FROM document_processing_queue
    WHERE completed_at >= NOW() - INTERVAL '24 hours';

END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION get_processing_dashboard() IS
'Quick dashboard metrics for document processing monitoring';


-- ================================================================================
-- USAGE EXAMPLES
-- ================================================================================

/*
-- Quick dashboard
SELECT * FROM get_processing_dashboard();

-- Manual review queue
SELECT * FROM pending_manual_review;

-- Check for alerts
SELECT * FROM (
    SELECT 'ALERT: Stalled Documents' AS alert, COUNT(*) AS count
    FROM document_processing_queue
    WHERE status = 'processing' AND started_at < NOW() - INTERVAL '10 minutes'

    UNION ALL

    SELECT 'ALERT: Large Backlog', COUNT(*)
    FROM document_processing_queue
    WHERE status = 'queued'
) alerts
WHERE count > 0;
*/


SELECT '✅ Document processing monitoring queries created successfully' AS status;
