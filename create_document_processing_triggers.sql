-- ================================================================================
-- Document Processing Triggers and Helper Functions
-- ================================================================================
-- Purpose: Automatically queue uploaded documents for LLM processing
-- Dependencies: document_uploads, document_processing_queue tables (already exist)
-- ================================================================================

-- ================================================================================
-- FUNCTION 1: Auto-queue document for processing
-- ================================================================================

CREATE OR REPLACE FUNCTION auto_queue_document_for_processing()
RETURNS TRIGGER AS $$
DECLARE
    v_priority INTEGER;
BEGIN
    -- Assign priority based on scope (lower = higher priority)
    v_priority := CASE NEW.scope
        WHEN 2 THEN 3  -- Scope 2 (Electricity) - High priority
        WHEN 1 THEN 5  -- Scope 1 (Fuels) - Medium priority
        WHEN 3 THEN 7  -- Scope 3 (Logistics) - Low priority
        ELSE 5         -- Default
    END;

    -- Insert into processing queue
    INSERT INTO document_processing_queue (
        document_upload_id,
        status,
        priority,
        retry_count,
        max_retries,
        created_at,
        updated_at
    ) VALUES (
        NEW.id,
        'queued',
        v_priority,
        0,
        3,  -- Max 3 retry attempts
        NOW(),
        NOW()
    );

    -- Update document status
    NEW.processing_status := 'pending';
    NEW.extraction_status := 'not_started';

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION auto_queue_document_for_processing() IS
'Automatically queues uploaded documents for LLM processing.
Triggered on INSERT into document_uploads table.
Priority: Scope 2=3, Scope 1=5, Scope 3=7 (lower=higher priority)';


-- ================================================================================
-- FUNCTION 2: Update document status when queue status changes
-- ================================================================================

CREATE OR REPLACE FUNCTION update_document_on_queue_change()
RETURNS TRIGGER AS $$
BEGIN
    -- Sync document_uploads status with queue status
    IF NEW.status = 'processing' THEN
        UPDATE document_uploads
        SET extraction_status = 'in_progress',
            updated_at = NOW()
        WHERE id = NEW.document_upload_id;

    ELSIF NEW.status = 'completed' THEN
        UPDATE document_uploads
        SET extraction_status = 'completed',
            processing_status = 'completed',
            updated_at = NOW()
        WHERE id = NEW.document_upload_id;

    ELSIF NEW.status = 'failed' AND NEW.retry_count >= NEW.max_retries THEN
        UPDATE document_uploads
        SET extraction_status = 'error',
            processing_status = 'failed',
            extraction_errors = NEW.error_message,
            updated_at = NOW()
        WHERE id = NEW.document_upload_id;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION update_document_on_queue_change() IS
'Synchronizes document_uploads status with document_processing_queue status.
Triggered on UPDATE to document_processing_queue table.';


-- ================================================================================
-- FUNCTION 3: Link emission record back to document
-- ================================================================================

CREATE OR REPLACE FUNCTION link_emission_to_document(
    p_document_id UUID,
    p_emission_id UUID,
    p_scope INTEGER,
    p_extracted_data JSONB,
    p_confidence_score NUMERIC
) RETURNS VOID AS $$
BEGIN
    -- Update document_uploads with emission link
    UPDATE document_uploads
    SET linked_emission_entry_id = p_emission_id,
        extracted_data = p_extracted_data,
        extraction_confidence_score = p_confidence_score,
        updated_at = NOW()
    WHERE id = p_document_id;

    RAISE NOTICE 'Linked document % to emission %', p_document_id, p_emission_id;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION link_emission_to_document(UUID, UUID, INTEGER, JSONB, NUMERIC) IS
'Links an emission record back to the source document after successful processing.
Called by Python service after insert_scope1/2/3_emission() succeeds.';


-- ================================================================================
-- FUNCTION 4: Retry failed document
-- ================================================================================

CREATE OR REPLACE FUNCTION retry_failed_document(p_document_id UUID)
RETURNS TEXT AS $$
DECLARE
    v_queue_id UUID;
    v_retry_count INTEGER;
    v_max_retries INTEGER;
BEGIN
    -- Get queue record
    SELECT id, retry_count, max_retries
    INTO v_queue_id, v_retry_count, v_max_retries
    FROM document_processing_queue
    WHERE document_upload_id = p_document_id
      AND status = 'failed'
    ORDER BY created_at DESC
    LIMIT 1;

    IF v_queue_id IS NULL THEN
        RETURN 'ERROR: No failed queue record found for document ' || p_document_id;
    END IF;

    IF v_retry_count >= v_max_retries THEN
        RETURN 'ERROR: Maximum retries exceeded (' || v_max_retries || ')';
    END IF;

    -- Reset queue record for retry
    UPDATE document_processing_queue
    SET status = 'queued',
        retry_count = retry_count + 1,
        error_message = NULL,
        started_at = NULL,
        completed_at = NULL,
        worker_id = NULL,
        updated_at = NOW()
    WHERE id = v_queue_id;

    -- Reset document status
    UPDATE document_uploads
    SET extraction_status = 'not_started',
        processing_status = 'pending',
        updated_at = NOW()
    WHERE id = p_document_id;

    RETURN 'SUCCESS: Document queued for retry (attempt ' || (v_retry_count + 1) || ')';
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION retry_failed_document(UUID) IS
'Retries processing for a failed document if retry limit not exceeded.
Resets queue status to queued and increments retry_count.';


-- ================================================================================
-- FUNCTION 5: Manually queue document (for re-processing)
-- ================================================================================

CREATE OR REPLACE FUNCTION manually_queue_document(
    p_document_id UUID,
    p_priority INTEGER DEFAULT 5
) RETURNS TEXT AS $$
DECLARE
    v_existing_queue_id UUID;
BEGIN
    -- Check if already queued or processing
    SELECT id INTO v_existing_queue_id
    FROM document_processing_queue
    WHERE document_upload_id = p_document_id
      AND status IN ('queued', 'processing')
    LIMIT 1;

    IF v_existing_queue_id IS NOT NULL THEN
        RETURN 'ERROR: Document already queued or processing';
    END IF;

    -- Add to queue
    INSERT INTO document_processing_queue (
        document_upload_id,
        status,
        priority,
        retry_count,
        max_retries
    ) VALUES (
        p_document_id,
        'queued',
        p_priority,
        0,
        3
    );

    -- Update document status
    UPDATE document_uploads
    SET extraction_status = 'not_started',
        processing_status = 'pending',
        updated_at = NOW()
    WHERE id = p_document_id;

    RETURN 'SUCCESS: Document manually queued with priority ' || p_priority;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION manually_queue_document(UUID, INTEGER) IS
'Manually queues a document for processing with specified priority.
Useful for re-processing previously completed documents.';


-- ================================================================================
-- FUNCTION 6: Get queue health metrics (monitoring)
-- ================================================================================

CREATE OR REPLACE FUNCTION get_queue_health()
RETURNS TABLE(
    metric VARCHAR,
    value TEXT
) AS $$
BEGIN
    RETURN QUERY
    SELECT 'queued_documents'::VARCHAR, COUNT(*)::TEXT
    FROM document_processing_queue
    WHERE status = 'queued'

    UNION ALL

    SELECT 'processing_documents'::VARCHAR, COUNT(*)::TEXT
    FROM document_processing_queue
    WHERE status = 'processing'

    UNION ALL

    SELECT 'failed_documents_24h'::VARCHAR, COUNT(*)::TEXT
    FROM document_processing_queue
    WHERE status = 'failed'
      AND completed_at >= NOW() - INTERVAL '24 hours'

    UNION ALL

    SELECT 'avg_processing_time_ms'::VARCHAR,
           COALESCE(ROUND(AVG(processing_time_ms))::TEXT, '0')
    FROM document_processing_queue
    WHERE status = 'completed'
      AND completed_at >= NOW() - INTERVAL '24 hours'

    UNION ALL

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

COMMENT ON FUNCTION get_queue_health() IS
'Returns key metrics for monitoring document processing queue health.
Metrics: queued, processing, failed (24h), avg processing time, success rate (24h).';


-- ================================================================================
-- TRIGGERS
-- ================================================================================

-- Drop existing triggers if they exist
DROP TRIGGER IF EXISTS trigger_auto_queue_document ON document_uploads;
DROP TRIGGER IF EXISTS trigger_update_document_status ON document_processing_queue;

-- Trigger 1: Auto-queue documents when uploaded
CREATE TRIGGER trigger_auto_queue_document
    BEFORE INSERT ON document_uploads
    FOR EACH ROW
    EXECUTE FUNCTION auto_queue_document_for_processing();

COMMENT ON TRIGGER trigger_auto_queue_document ON document_uploads IS
'Automatically queues uploaded documents for LLM processing.
Fires BEFORE INSERT on document_uploads table.';


-- Trigger 2: Sync document status when queue status changes
CREATE TRIGGER trigger_update_document_status
    AFTER UPDATE ON document_processing_queue
    FOR EACH ROW
    WHEN (OLD.status IS DISTINCT FROM NEW.status)
    EXECUTE FUNCTION update_document_on_queue_change();

COMMENT ON TRIGGER trigger_update_document_status ON document_processing_queue IS
'Synchronizes document_uploads status with queue status changes.
Fires AFTER UPDATE on document_processing_queue when status changes.';


-- ================================================================================
-- VERIFICATION
-- ================================================================================

SELECT '✅ DOCUMENT PROCESSING TRIGGERS INSTALLED SUCCESSFULLY' as status;

-- Show created functions
SELECT
    routine_name,
    routine_type
FROM information_schema.routines
WHERE routine_name LIKE '%document%'
  AND routine_schema = 'public'
ORDER BY routine_name;

-- Show created triggers
SELECT
    trigger_name,
    event_object_table,
    action_timing,
    event_manipulation
FROM information_schema.triggers
WHERE trigger_name LIKE '%document%'
ORDER BY trigger_name;
