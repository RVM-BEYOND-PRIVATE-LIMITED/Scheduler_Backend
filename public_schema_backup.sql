


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE SCHEMA IF NOT EXISTS "public";


ALTER SCHEMA "public" OWNER TO "pg_database_owner";


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE TYPE "public"."gender_type" AS ENUM (
    'Male',
    'Female',
    'Other',
    'Prefer not to say'
);


ALTER TYPE "public"."gender_type" OWNER TO "postgres";


CREATE TYPE "public"."installment_status" AS ENUM (
    'Due',
    'Paid',
    'Partially Paid',
    'Overdue'
);


ALTER TYPE "public"."installment_status" OWNER TO "postgres";


CREATE TYPE "public"."notice_period_type" AS ENUM (
    'Immediate',
    '15 Days',
    '30 Days',
    '45 Days',
    '60 Days',
    '90 Days'
);


ALTER TYPE "public"."notice_period_type" OWNER TO "postgres";


CREATE TYPE "public"."ticket_priority" AS ENUM (
    'Low',
    'Medium',
    'High'
);


ALTER TYPE "public"."ticket_priority" OWNER TO "postgres";


CREATE TYPE "public"."ticket_status" AS ENUM (
    'Open',
    'In Progress',
    'Resolved'
);


ALTER TYPE "public"."ticket_status" OWNER TO "postgres";


CREATE TYPE "public"."user_role" AS ENUM (
    'admin',
    'faculty',
    'admin_executive',
    'accounts',
    'placement_head',
    'placement_executive',
    'super_admin'
);


ALTER TYPE "public"."user_role" OWNER TO "postgres";


CREATE TYPE "public"."working_status_type" AS ENUM (
    'Yes',
    'No'
);


ALTER TYPE "public"."working_status_type" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."apply_payment_to_installments"("p_payment_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_admission_id UUID;
    v_total_paid_so_far NUMERIC;
    v_cumulative_paid NUMERIC := 0;
    r_inst RECORD;
BEGIN
    -- 1. Identify the student/admission for this payment
    SELECT admission_id INTO v_admission_id
    FROM public.payments
    WHERE id = p_payment_id;

    IF NOT FOUND THEN 
        RAISE EXCEPTION 'Payment ID % not found', p_payment_id; 
    END IF;

    -- 2. Calculate the GLOBAL total paid by this student across ALL payments
    -- This ensures early payments are accounted for correctly
    SELECT COALESCE(SUM(amount_paid), 0)
    INTO v_total_paid_so_far
    FROM public.payments
    WHERE admission_id = v_admission_id;

    v_cumulative_paid := v_total_paid_so_far;

    -- 3. Iterate through ALL installments in chronological order
    FOR r_inst IN
        SELECT id, amount, due_date
        FROM public.installments
        WHERE admission_id = v_admission_id
        ORDER BY due_date ASC, created_at ASC
    LOOP
        -- If the student's total pool of money covers this installment
        IF v_cumulative_paid >= r_inst.amount THEN
            UPDATE public.installments 
            SET status = 'Paid' 
            WHERE id = r_inst.id;
            
            v_cumulative_paid := v_cumulative_paid - r_inst.amount;
        
        -- If the money only covers PART of this installment
        ELSIF v_cumulative_paid > 0 THEN
            UPDATE public.installments 
            SET status = 'Pending' -- You could add a 'Partial' status here if desired
            WHERE id = r_inst.id;
            
            v_cumulative_paid := 0;
            
        -- If no money is left for this installment
        ELSE
            -- Check if it's already overdue based on date
            IF r_inst.due_date < CURRENT_DATE THEN
                UPDATE public.installments SET status = 'Overdue' WHERE id = r_inst.id;
            ELSE
                UPDATE public.installments SET status = 'Pending' WHERE id = r_inst.id;
            END IF;
        END IF;
    END LOOP;
END;
$$;


ALTER FUNCTION "public"."apply_payment_to_installments"("p_payment_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."check_assignee_is_admin"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$ 
DECLARE assignee_role public.user_role; 
BEGIN 
    IF NEW.assignee_id IS NULL THEN RETURN NEW; END IF; 
    SELECT role INTO assignee_role FROM public.users WHERE id = NEW.assignee_id; 
    IF assignee_role IS DISTINCT FROM 'admin' THEN 
        RAISE EXCEPTION 'Assignee Error: User with ID % is not an admin.', NEW.assignee_id; 
    END IF; 
    RETURN NEW; 
END; 
$$;


ALTER FUNCTION "public"."check_assignee_is_admin"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_admission_and_student"("p_student_name" "text", "p_student_phone_number" "text", "p_father_name" "text", "p_father_phone_number" "text", "p_permanent_address" "text", "p_current_address" "text", "p_identification_type" "text", "p_identification_number" "text", "p_date_of_admission" "date", "p_course_start_date" "date", "p_batch_preference" "text", "p_remarks" "text", "p_certificate_id" "uuid", "p_discount" numeric, "p_course_ids" "uuid"[], "p_installments" "jsonb", "p_location_id" integer) RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  v_student_id UUID;
  v_admission_id UUID;
  v_admission_number TEXT; 
  v_total_course_price NUMERIC;
  v_certificate_cost NUMERIC;
  v_base_amount NUMERIC;
  v_final_payable_amount NUMERIC;
  v_course_id UUID;
  v_installment JSONB;
BEGIN
  
  -- 1. Check duplicate phone
  IF EXISTS (SELECT 1 FROM public.students WHERE phone_number = p_student_phone_number) THEN
    RAISE EXCEPTION 'Student with phone number % already exists.', p_student_phone_number;
  END IF;

  -- 2. Create Student
  CREATE SEQUENCE IF NOT EXISTS admission_number_seq;
  
  v_admission_number := 'RVM-' || EXTRACT(YEAR FROM NOW()) || '-' || 
                        lpad(nextval('admission_number_seq')::text, 4, '0');

  INSERT INTO public.students (
      name, phone_number, admission_number, location_id
  )
  VALUES (
      p_student_name, p_student_phone_number, v_admission_number, p_location_id
  )
  RETURNING id INTO v_student_id;

  -- 3. Financial Calculations
  SELECT COALESCE(SUM(price), 0) INTO v_total_course_price
  FROM public.courses WHERE id = ANY(p_course_ids);

  SELECT COALESCE(cost, 0) INTO v_certificate_cost
  FROM public.certificates WHERE id = p_certificate_id;

  v_base_amount := v_total_course_price + v_certificate_cost;
  v_final_payable_amount := (v_base_amount - p_discount);

  -- 4. Create Admission
  INSERT INTO public.admissions (
    student_id, certificate_id, 
    base_amount,       -- <--- New Column
    base_tuition_fees, -- <--- Existing Column (Critical for Dashboard)
    subtotal, total_invoice_amount,
    discount, final_payable_amount, 
    remarks, date_of_admission, course_start_date, batch_preference,
    father_name, father_phone_number, permanent_address, current_address,
    identification_type, identification_number,
    student_name, student_phone_number,
    total_payable_amount,
    approval_status, is_gst_exempt, gst_rate
  )
  VALUES (
    v_student_id, p_certificate_id, 
    v_base_amount, -- Save to base_amount
    v_base_amount, -- Save to base_tuition_fees (Syncs the values)
    v_base_amount, v_base_amount,
    p_discount, v_final_payable_amount, 
    p_remarks, p_date_of_admission, p_course_start_date, p_batch_preference,
    p_father_name, p_father_phone_number, p_permanent_address, p_current_address,
    p_identification_type, p_identification_number,
    p_student_name, p_student_phone_number,
    v_final_payable_amount, 
    'Approved', true, 0
  )
  RETURNING id INTO v_admission_id;

  -- 5. Link Courses
  FOREACH v_course_id IN ARRAY p_course_ids
  LOOP
    INSERT INTO public.admission_courses (admission_id, course_id)
    VALUES (v_admission_id, v_course_id);
  END LOOP;

  -- 6. Create Installments
  FOR v_installment IN SELECT * FROM jsonb_array_elements(p_installments)
  LOOP
    INSERT INTO public.installments (
      admission_id, due_date, amount, status
    )
    VALUES (
      v_admission_id,
      (v_installment->>'due_date')::DATE,
      (v_installment->>'amount')::NUMERIC,
      'Pending'
    );
  END LOOP;

  RETURN v_admission_id;
END;
$$;


ALTER FUNCTION "public"."create_admission_and_student"("p_student_name" "text", "p_student_phone_number" "text", "p_father_name" "text", "p_father_phone_number" "text", "p_permanent_address" "text", "p_current_address" "text", "p_identification_type" "text", "p_identification_number" "text", "p_date_of_admission" "date", "p_course_start_date" "date", "p_batch_preference" "text", "p_remarks" "text", "p_certificate_id" "uuid", "p_discount" numeric, "p_course_ids" "uuid"[], "p_installments" "jsonb", "p_location_id" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_admission_and_student"("p_student_name" "text", "p_student_phone_number" "text", "p_father_name" "text" DEFAULT NULL::"text", "p_father_phone_number" "text" DEFAULT NULL::"text", "p_permanent_address" "text" DEFAULT NULL::"text", "p_current_address" "text" DEFAULT NULL::"text", "p_identification_type" "text" DEFAULT NULL::"text", "p_identification_number" "text" DEFAULT NULL::"text", "p_date_of_admission" "date" DEFAULT NULL::"date", "p_course_start_date" "date" DEFAULT NULL::"date", "p_batch_preference" "text" DEFAULT NULL::"text", "p_remarks" "text" DEFAULT NULL::"text", "p_certificate_id" "uuid" DEFAULT NULL::"uuid", "p_discount" numeric DEFAULT 0, "p_course_ids" "uuid"[] DEFAULT '{}'::"uuid"[], "p_installments" "jsonb" DEFAULT '[]'::"jsonb", "p_location_id" integer DEFAULT NULL::integer, "p_source_intake_id" "uuid" DEFAULT NULL::"uuid", "p_admitted_by" "uuid" DEFAULT NULL::"uuid") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_student_id UUID;
  v_admission_id UUID;
  v_admission_number TEXT; 
  v_total_course_price NUMERIC;
  v_certificate_cost NUMERIC;
  v_base_amount NUMERIC;
  v_final_payable_amount NUMERIC;
  v_course_id UUID;
  v_installment JSONB;
BEGIN
  -- 1. Check duplicate phone
  IF EXISTS (SELECT 1 FROM public.students WHERE phone_number = p_student_phone_number) THEN
    RAISE EXCEPTION 'Student with phone number % already exists.', p_student_phone_number;
  END IF;

  -- 2. Create Student and Generate Admission Number
  CREATE SEQUENCE IF NOT EXISTS admission_number_seq;
  v_admission_number := 'RVM-' || EXTRACT(YEAR FROM NOW()) || '-' || 
                        lpad(nextval('admission_number_seq')::text, 4, '0');

  INSERT INTO public.students (name, phone_number, admission_number, location_id)
  VALUES (p_student_name, p_student_phone_number, v_admission_number, p_location_id)
  RETURNING id INTO v_student_id;

  -- 3. Financial Calculations
  -- COALESCE ensures these values are never null
  SELECT COALESCE(SUM(price), 0) INTO v_total_course_price 
  FROM public.courses 
  WHERE id = ANY(p_course_ids);

  SELECT COALESCE(cost, 0) INTO v_certificate_cost 
  FROM public.certificates 
  WHERE id = p_certificate_id;

  v_base_amount := v_total_course_price + v_certificate_cost;
  
  -- Safety check to satisfy NOT NULL constraints
  IF v_base_amount IS NULL THEN
    v_base_amount := 0;
  END IF;

  v_final_payable_amount := (v_base_amount - p_discount);

  -- 4. Create Admission record
  INSERT INTO public.admissions (
    student_id, 
    certificate_id, 
    base_amount, 
    base_tuition_fees, -- Fixed: now explicitly receives v_base_amount
    subtotal, 
    total_invoice_amount, 
    discount, 
    final_payable_amount, 
    remarks, 
    date_of_admission, 
    course_start_date, 
    batch_preference, 
    father_name, 
    father_phone_number, 
    permanent_address, 
    current_address, 
    identification_type, 
    identification_number, 
    student_name, 
    student_phone_number, 
    total_payable_amount,
    approval_status, 
    is_gst_exempt, 
    gst_rate, 
    location_id, 
    source_intake_id, 
    admitted_by
  )
  VALUES (
    v_student_id, 
    p_certificate_id, 
    v_base_amount, 
    v_base_amount, 
    v_base_amount, 
    v_base_amount, 
    p_discount, 
    v_final_payable_amount, 
    p_remarks, 
    p_date_of_admission, 
    p_course_start_date, 
    p_batch_preference, 
    p_father_name, 
    p_father_phone_number, 
    p_permanent_address, 
    p_current_address, 
    p_identification_type, 
    p_identification_number, 
    p_student_name, 
    p_student_phone_number, 
    v_final_payable_amount, 
    'Approved', 
    true, 
    0, 
    p_location_id, 
    p_source_intake_id, 
    p_admitted_by
  )
  RETURNING id INTO v_admission_id;

  -- 5. Link Courses to the Admission
  FOREACH v_course_id IN ARRAY p_course_ids LOOP
    INSERT INTO public.admission_courses (admission_id, course_id) 
    VALUES (v_admission_id, v_course_id);
  END LOOP;

  -- 6. Create Installment Schedule
  FOR v_installment IN SELECT * FROM jsonb_array_elements(p_installments) LOOP
    INSERT INTO public.installments (admission_id, due_date, amount, status)
    VALUES (
      v_admission_id, 
      (v_installment->>'due_date')::DATE, 
      (v_installment->>'amount')::NUMERIC, 
      'Pending'
    );
  END LOOP;

  RETURN v_admission_id;
END;
$$;


ALTER FUNCTION "public"."create_admission_and_student"("p_student_name" "text", "p_student_phone_number" "text", "p_father_name" "text", "p_father_phone_number" "text", "p_permanent_address" "text", "p_current_address" "text", "p_identification_type" "text", "p_identification_number" "text", "p_date_of_admission" "date", "p_course_start_date" "date", "p_batch_preference" "text", "p_remarks" "text", "p_certificate_id" "uuid", "p_discount" numeric, "p_course_ids" "uuid"[], "p_installments" "jsonb", "p_location_id" integer, "p_source_intake_id" "uuid", "p_admitted_by" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_course_with_books"("p_name" "text", "p_price" numeric, "p_book_ids" "uuid"[]) RETURNS "uuid"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  new_course_id UUID;
  book_id UUID;
BEGIN
  INSERT INTO public.courses (name, price)
  VALUES (p_name, p_price)
  RETURNING id INTO new_course_id;

  IF array_length(p_book_ids, 1) > 0 THEN
    FOREACH book_id IN ARRAY p_book_ids
    LOOP
      INSERT INTO public.course_books (course_id, book_id)
      VALUES (new_course_id, book_id);
    END LOOP;
  END IF;

  RETURN new_course_id;
END;
$$;


ALTER FUNCTION "public"."create_course_with_books"("p_name" "text", "p_price" numeric, "p_book_ids" "uuid"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_sync_student_changes_to_admissions"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    -- Only run the update if one of these three columns actually changed
    IF (OLD.name IS DISTINCT FROM NEW.name OR 
        OLD.phone_number IS DISTINCT FROM NEW.phone_number OR 
        OLD.location_id IS DISTINCT FROM NEW.location_id) THEN
        
        UPDATE public.admissions
        SET 
            location_id = NEW.location_id,
            student_name = NEW.name,
            student_phone_number = NEW.phone_number,
            updated_at = now()
        WHERE student_id = NEW.id;
    END IF;

    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."fn_sync_student_changes_to_admissions"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_sync_student_location_to_admissions"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    -- Only update if the location_id actually changed
    IF (OLD.location_id IS DISTINCT FROM NEW.location_id) THEN
        UPDATE public.admissions
        SET location_id = NEW.location_id,
            updated_at = now()
        WHERE student_id = NEW.id;
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."fn_sync_student_location_to_admissions"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."generate_admission_number"() RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_year INTEGER := EXTRACT(YEAR FROM CURRENT_DATE);
    v_next INTEGER;
BEGIN
    INSERT INTO admission_number_counters (year, last_number)
    VALUES (v_year, 1)
    ON CONFLICT (year)
    DO UPDATE SET last_number = admission_number_counters.last_number + 1
    RETURNING last_number INTO v_next;

    RETURN format(
        'RVM-%s-%s',
        v_year,
        lpad(v_next::text, 4, '0')
    );
END;
$$;


ALTER FUNCTION "public"."generate_admission_number"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."generate_admission_number"("p_location_id" integer) RETURNS "text"
    LANGUAGE "plpgsql"
    AS $_$
DECLARE
    v_year TEXT := EXTRACT(YEAR FROM CURRENT_DATE)::TEXT;
    v_prefix TEXT := 'RVM-' || v_year || '-';
    v_last_number INTEGER;
    v_next_number INTEGER;
BEGIN
    SELECT COALESCE(
        MAX(
            (regexp_replace(admission_number, '.*-(\d+)$', '\1'))::INTEGER
        ),
        0
    )
    INTO v_last_number
    FROM public.students
    WHERE admission_number LIKE v_prefix || '%'
      AND location_id = p_location_id;

    v_next_number := v_last_number + 1;

    RETURN v_prefix || LPAD(v_next_number::TEXT, 4, '0');
END;
$_$;


ALTER FUNCTION "public"."generate_admission_number"("p_location_id" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."generate_receipt_number"() RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_today DATE := CURRENT_DATE;
    v_next_number INTEGER;
BEGIN
    -- Ensure row exists
    INSERT INTO receipt_counters (receipt_date, last_number)
    VALUES (v_today, 0)
    ON CONFLICT (receipt_date) DO NOTHING;

    -- Atomic increment
    UPDATE receipt_counters
    SET last_number = last_number + 1
    WHERE receipt_date = v_today
    RETURNING last_number INTO v_next_number;

    RETURN
        'RVM-' ||
        TO_CHAR(v_today, 'DDMMYYYY') ||
        '-' ||
        LPAD(v_next_number::TEXT, 5, '0');
END;
$$;


ALTER FUNCTION "public"."generate_receipt_number"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."generate_rvm_receipt_number"() RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    current_date_val date := current_date;
    fy_start int;
    fy_end int;
    fy_string text;
    next_num int;
    final_receipt text;
BEGIN
    -- 1. Determine Financial Year (April to March logic)
    IF EXTRACT(MONTH FROM current_date_val) IN (1, 2, 3) THEN
        fy_start := (EXTRACT(YEAR FROM current_date_val) - 1) % 100;
        fy_end := (EXTRACT(YEAR FROM current_date_val)) % 100;
    ELSE
        fy_start := (EXTRACT(YEAR FROM current_date_val)) % 100;
        fy_end := (EXTRACT(YEAR FROM current_date_val) + 1) % 100;
    END IF;

    -- Format the FY string with a hyphen: "26-27"
    fy_string := TO_CHAR(fy_start, 'FM00') || '-' || TO_CHAR(fy_end, 'FM00');

    -- 2. Increment global counter
    INSERT INTO public.receipt_counters (receipt_date, last_number)
    VALUES ('1900-01-01', 1)
    ON CONFLICT (receipt_date) 
    DO UPDATE SET last_number = receipt_counters.last_number + 1
    RETURNING last_number INTO next_num;

    -- 3. Final Format: RVMBEYOND/26-27/00001
    final_receipt := 'RVMBEYOND/' || fy_string || '/' || LPAD(next_num::text, 5, '0');

    RETURN final_receipt;
END;
$$;


ALTER FUNCTION "public"."generate_rvm_receipt_number"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_admission_dashboard"("search_term" "text" DEFAULT ''::"text") RETURNS TABLE("admission_id" "uuid", "admission_number" "text", "student_name" "text", "student_phone_number" "text", "certificate_name" "text", "batch_name" "text", "total_payable_amount" numeric, "total_paid" numeric, "balance_due" numeric, "status" "text", "created_at" timestamp with time zone)
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RETURN QUERY
    SELECT 
        v.admission_id,
        v.admission_number,
        v.student_name,
        v.student_phone_number,
        v.certificate_name,
        v.batch_name,
        v.total_fees AS total_payable_amount,
        v.total_paid,
        v.balance_due,
        v.status,
        v.created_at
    FROM v_admission_financial_summary v
    WHERE
        search_term = ''
        OR v.admission_number ILIKE '%' || search_term || '%'
        OR v.student_name ILIKE '%' || search_term || '%'
        OR v.student_phone_number ILIKE '%' || search_term || '%'
    ORDER BY v.created_at DESC;
END;
$$;


ALTER FUNCTION "public"."get_admission_dashboard"("search_term" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_admission_dashboard_v2"("search_term" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  v_metrics JSONB;
  v_admissions_list JSONB;
BEGIN
  
  -- 1. Metrics (unchanged)
  SELECT jsonb_build_object(
    'totalAdmissions', (SELECT COUNT(*) FROM admissions),
    'admissionsThisMonth', (SELECT COUNT(*) FROM admissions WHERE date_trunc('month', created_at) = date_trunc('month', CURRENT_DATE)),
    'totalCollected', (SELECT COALESCE(SUM(amount_paid), 0) FROM payments),
    'revenueCollectedThisMonth', (SELECT COALESCE(SUM(amount_paid), 0) FROM payments WHERE date_trunc('month', payment_date) = date_trunc('month', CURRENT_DATE)),
    'totalOutstanding', (SELECT COALESCE(SUM(amount), 0) FROM installments WHERE status IN ('Pending', 'Overdue')),
    'overdueCount', (SELECT COUNT(DISTINCT admission_id) FROM installments WHERE status = 'Overdue')
  ) INTO v_metrics;
  
  -- 2. Admissions List (THE CRITICAL PART)
  SELECT jsonb_agg(
    jsonb_build_object(
      -- IDENTIFIERS
      'admission_id', a.id,
      'admission_number', COALESCE(s.admission_number, 'N/A'),
      'student_name', s.name,
      'student_phone_number', s.phone_number,
      
      -- COURSE / CERTIFICATE
      'course_name', COALESCE(
          cert.name, 
          (SELECT string_agg(c.name, ', ') FROM admission_courses ac JOIN courses c ON ac.course_id = c.id WHERE ac.admission_id = a.id),
          'No Course Selected'
      ),
      
      -- BATCH (Forcing the exact key 'batch_name')
      'batch_name', COALESCE(
          (SELECT b.name FROM batch_students bs JOIN batches b ON bs.batch_id = b.id WHERE bs.student_id = s.id LIMIT 1),
          'Not Allotted'
      ),

      -- FINANCIALS (Calculated from Installments to fix 0.00 issue)
      'total_fees', (SELECT COALESCE(SUM(amount), 0) FROM installments WHERE admission_id = a.id),
      'total_paid', COALESCE((SELECT SUM(p.amount_paid) FROM payments p WHERE p.admission_id = a.id), 0),
      'balance_due', (
          (SELECT COALESCE(SUM(amount), 0) FROM installments WHERE admission_id = a.id) 
          - 
          COALESCE((SELECT SUM(p.amount_paid) FROM payments p WHERE p.admission_id = a.id), 0)
      ),
      
      -- STATUS & DATES
      'status', a.approval_status,
      'created_at', a.created_at
    )
  )
  INTO v_admissions_list
  FROM admissions a
  JOIN students s ON a.student_id = s.id
  LEFT JOIN certificates cert ON a.certificate_id = cert.id
  WHERE 
    search_term IS NULL OR search_term = '' OR
    s.name ILIKE ('%' || search_term || '%') OR
    s.phone_number ILIKE ('%' || search_term || '%') OR
    s.admission_number ILIKE ('%' || search_term || '%')
  ORDER BY a.created_at DESC;
  
  -- 3. Return
  RETURN jsonb_build_object(
    'metrics', v_metrics,
    'admissions', COALESCE(v_admissions_list, '[]'::jsonb)
  );
  
END;
$$;


ALTER FUNCTION "public"."get_admission_dashboard_v2"("search_term" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_faculty_unique_student_count"("faculty_uuid" "uuid") RETURNS integer
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  RETURN (
    SELECT COUNT(DISTINCT bs.student_id)
    FROM batches b
    JOIN batch_students bs ON b.id = bs.batch_id
    WHERE b.faculty_id = faculty_uuid
  );
END;
$$;


ALTER FUNCTION "public"."get_faculty_unique_student_count"("faculty_uuid" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_unique_ticket_categories"() RETURNS TABLE("category" "text")
    LANGUAGE "plpgsql"
    AS $$ BEGIN RETURN QUERY SELECT DISTINCT t.category FROM tickets as t WHERE t.category IS NOT NULL; END; $$;


ALTER FUNCTION "public"."get_unique_ticket_categories"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_unique_ticket_categories"("p_location_id" integer) RETURNS TABLE("category" "text")
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  RETURN QUERY 
  SELECT DISTINCT t.category 
  FROM tickets as t
  WHERE t.category IS NOT NULL
    AND t.location_id = p_location_id; -- MODIFIED: Filter by location
END;
$$;


ALTER FUNCTION "public"."get_unique_ticket_categories"("p_location_id" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."mark_intake_converted"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  UPDATE public.admission_intakes
  SET admission_id = NEW.id
  WHERE id = NEW.source_intake_id;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."mark_intake_converted"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."merge_batches_transaction"("source_batch_id" "uuid", "target_batch_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  -- 1. Copy unique students from the source batch to the target batch.
  -- The "ON CONFLICT" clause prevents errors if a student is already in the target batch.
  INSERT INTO batch_students (batch_id, student_id)
  SELECT target_batch_id, s.student_id
  FROM batch_students s
  WHERE s.batch_id = source_batch_id
  ON CONFLICT (batch_id, student_id) DO NOTHING;

  -- 2. Delete the original source batch.
  DELETE FROM batches
  WHERE id = source_batch_id;
END;
$$;


ALTER FUNCTION "public"."merge_batches_transaction"("source_batch_id" "uuid", "target_batch_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."record_payment"("p_admission_id" "uuid", "p_amount_paid" numeric, "p_payment_date" "date", "p_payment_method" "text", "p_user_id" "uuid") RETURNS "uuid"
    LANGUAGE "plpgsql"
    AS $$ 
DECLARE 
    new_receipt_id UUID; 
    remaining_payment_amount NUMERIC := p_amount_paid; 
    installment_to_pay RECORD; 
BEGIN 
    -- 1. Create Receipt
    INSERT INTO public.receipts (admission_id, amount_paid, payment_date, payment_method, generated_by, receipt_number) 
    VALUES (p_admission_id, p_amount_paid, p_payment_date, p_payment_method, p_user_id, 'RCPT-' || upper(substr(md5(random()::text), 0, 10))) 
    RETURNING id INTO new_receipt_id; 
    
    -- 2. Link payment to installments (Logic from Fee Branch)
    FOR installment_to_pay IN 
        SELECT id, balance_due FROM public.v_installment_status 
        WHERE admission_id = p_admission_id AND status IN ('Overdue', 'Partially Paid', 'Due') 
        ORDER BY due_date ASC 
    LOOP 
        IF remaining_payment_amount <= 0 THEN EXIT; END IF; 
        DECLARE amount_to_apply NUMERIC; 
        BEGIN 
            amount_to_apply := LEAST(remaining_payment_amount, installment_to_pay.balance_due); 
            INSERT INTO public.receipt_installments (receipt_id, installment_id, amount_applied) 
            VALUES (new_receipt_id, installment_to_pay.id, amount_to_apply); 
            remaining_payment_amount := remaining_payment_amount - amount_to_apply; 
        END; 
    END LOOP; 
    
    RETURN new_receipt_id; 
END; 
$$;


ALTER FUNCTION "public"."record_payment"("p_admission_id" "uuid", "p_amount_paid" numeric, "p_payment_date" "date", "p_payment_method" "text", "p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."repair_all_student_ledgers"() RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_adm_record RECORD;
    v_count INTEGER := 0;
BEGIN
    -- Loop through every admission that has at least one payment
    FOR v_adm_record IN 
        SELECT DISTINCT admission_id FROM public.payments
    LOOP
        -- Reuse the FIFO logic we just built
        -- We pick the latest payment ID for that student to trigger the full recalculation
        PERFORM public.apply_payment_to_installments(
            (SELECT id FROM public.payments 
             WHERE admission_id = v_adm_record.admission_id 
             ORDER BY created_at DESC LIMIT 1)
        );
        v_count := v_count + 1;
    END LOOP;

    RETURN 'Success: ' || v_count || ' student ledgers have been synchronized.';
END;
$$;


ALTER FUNCTION "public"."repair_all_student_ledgers"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."reset_status_on_reapply"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    -- Only trigger logic if the status is moving from 'Re-apply Requested' to 'Applied'
    IF OLD.status = 'Re-apply Requested' AND NEW.status = 'Applied' THEN
        -- ✅ THE FIX: Explicitly keep reapply_granted as TRUE
        -- This acts as our permanent "Resubmitted" marker.
        NEW.reapply_granted := true;
        
        -- Reset logistics but keep the flag
        NEW.applied_at := now();
        NEW.rejection_reason := NULL;
    END IF;

    -- ✅ Ensure that if reapply_granted was already true, it NEVER flips back to false
    IF OLD.reapply_granted = true THEN
        NEW.reapply_granted := true;
    END IF;

    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."reset_status_on_reapply"() OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."ticket_chats" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "ticket_id" "uuid" NOT NULL,
    "message" "text" NOT NULL,
    "sender_user_id" "uuid",
    "sender_student_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."ticket_chats" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."send_admin_reply_and_update_status"("p_ticket_id" "uuid", "p_sender_user_id" "uuid", "p_message" "text") RETURNS SETOF "public"."ticket_chats"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  -- Insert the message into the chat table
  INSERT INTO public.ticket_chats (ticket_id, message, sender_user_id)
  VALUES (p_ticket_id, p_message, p_sender_user_id);

  -- Update the ticket status to 'In Progress' and update the timestamp
  UPDATE public.tickets
  SET 
    status = 'In Progress',
    updated_at = NOW()
  WHERE id = p_ticket_id;

  -- Return the newly created message so the frontend can display it immediately
  RETURN QUERY 
  SELECT * FROM public.ticket_chats 
  WHERE ticket_id = p_ticket_id 
  ORDER BY created_at DESC 
  LIMIT 1;
END;
$$;


ALTER FUNCTION "public"."send_admin_reply_and_update_status"("p_ticket_id" "uuid", "p_sender_user_id" "uuid", "p_message" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_admission_location"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  -- Fetch the location_id from the related student record
  SELECT location_id INTO NEW.location_id
  FROM public.students
  WHERE id = NEW.student_id;
  
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."sync_admission_location"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_batch_schedule"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  -- Convert text days in days_of_week to their corresponding integers
  -- 0=Sunday, 1=Monday, 2=Tuesday, 3=Wednesday, 4=Thursday, 5=Friday, 6=Saturday
  NEW.schedule := (
    SELECT array_agg(
      CASE 
        WHEN day = 'Sunday'    THEN 0
        WHEN day = 'Monday'    THEN 1
        WHEN day = 'Tuesday'   THEN 2
        WHEN day = 'Wednesday' THEN 3
        WHEN day = 'Thursday'  THEN 4
        WHEN day = 'Friday'    THEN 5
        WHEN day = 'Saturday'  THEN 6
      END
    )
    FROM unnest(NEW.days_of_week) AS day
  );
  
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."sync_batch_schedule"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_admission_full"("p_admission_id" "uuid", "p_batch_preference" "text" DEFAULT NULL::"text", "p_certificate_id" "uuid" DEFAULT NULL::"uuid", "p_course_ids" "uuid"[] DEFAULT '{}'::"uuid"[], "p_course_start_date" "date" DEFAULT NULL::"date", "p_current_address" "text" DEFAULT NULL::"text", "p_date_of_admission" "date" DEFAULT NULL::"date", "p_discount" numeric DEFAULT 0, "p_father_name" "text" DEFAULT NULL::"text", "p_father_phone_number" "text" DEFAULT NULL::"text", "p_identification_number" "text" DEFAULT NULL::"text", "p_identification_type" "text" DEFAULT NULL::"text", "p_installments" "jsonb" DEFAULT '[]'::"jsonb", "p_location_id" "text" DEFAULT NULL::"text", "p_permanent_address" "text" DEFAULT NULL::"text", "p_remarks" "text" DEFAULT NULL::"text", "p_student_name" "text" DEFAULT NULL::"text", "p_student_phone_number" "text" DEFAULT NULL::"text") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $_$
DECLARE
    v_student_id UUID;
    v_new_total NUMERIC;
BEGIN
    -- A. Calculate the sum of installments to ensure financial integrity
    SELECT COALESCE(SUM((elem->>'amount')::numeric), 0) INTO v_new_total
    FROM jsonb_array_elements(p_installments) AS elem;

    -- B. Find the linked student
    SELECT student_id INTO v_student_id FROM public.admissions WHERE id = p_admission_id;

    -- C. Update Student details (using 'name' column)
    UPDATE public.students 
    SET 
        name = p_student_name,
        phone_number = p_student_phone_number,
        location_id = CASE 
            WHEN p_location_id ~ '^[0-9]+$' THEN p_location_id::integer 
            ELSE location_id 
        END
    WHERE id = v_student_id;

    -- D. Update Admission details and Sync Totals
    UPDATE public.admissions 
    SET 
        final_payable_amount = v_new_total, -- Forces Dashboard to match Installments
        total_payable_amount = v_new_total,
        discount = p_discount,
        date_of_admission = p_date_of_admission,
        course_start_date = p_course_start_date,
        batch_preference = p_batch_preference,
        remarks = p_remarks,
        certificate_id = p_certificate_id,
        father_name = p_father_name,
        father_phone_number = p_father_phone_number,
        current_address = p_current_address,
        permanent_address = p_permanent_address,
        identification_type = p_identification_type,
        identification_number = p_identification_number
    WHERE id = p_admission_id;

    -- E. Sync Course Links
    DELETE FROM public.admission_courses WHERE admission_id = p_admission_id;
    INSERT INTO public.admission_courses (admission_id, course_id)
    SELECT p_admission_id, unnest(p_course_ids);

    -- F. Sync Installments
    DELETE FROM public.installments WHERE admission_id = p_admission_id;
    INSERT INTO public.installments (admission_id, amount, due_date, status)
    SELECT 
        p_admission_id, 
        (elem->>'amount')::numeric, 
        (elem->>'due_date')::date, 
        COALESCE(elem->>'status', 'Pending')
    FROM jsonb_array_elements(p_installments) AS elem;

END;
$_$;


ALTER FUNCTION "public"."update_admission_full"("p_admission_id" "uuid", "p_batch_preference" "text", "p_certificate_id" "uuid", "p_course_ids" "uuid"[], "p_course_start_date" "date", "p_current_address" "text", "p_date_of_admission" "date", "p_discount" numeric, "p_father_name" "text", "p_father_phone_number" "text", "p_identification_number" "text", "p_identification_type" "text", "p_installments" "jsonb", "p_location_id" "text", "p_permanent_address" "text", "p_remarks" "text", "p_student_name" "text", "p_student_phone_number" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_admission_full"("p_admission_id" "uuid", "p_student_name" "text", "p_student_phone_number" "text", "p_father_name" "text" DEFAULT NULL::"text", "p_father_phone_number" "text" DEFAULT NULL::"text", "p_permanent_address" "text" DEFAULT NULL::"text", "p_current_address" "text" DEFAULT NULL::"text", "p_identification_type" "text" DEFAULT NULL::"text", "p_identification_number" "text" DEFAULT NULL::"text", "p_date_of_admission" "date" DEFAULT CURRENT_DATE, "p_course_start_date" "date" DEFAULT NULL::"date", "p_batch_preference" "text" DEFAULT NULL::"text", "p_remarks" "text" DEFAULT NULL::"text", "p_certificate_id" "uuid" DEFAULT NULL::"uuid", "p_discount" numeric DEFAULT 0, "p_course_ids" "uuid"[] DEFAULT ARRAY[]::"uuid"[], "p_installments" "jsonb" DEFAULT '[]'::"jsonb", "p_location_id" "text" DEFAULT NULL::"text", "p_updated_by" "uuid" DEFAULT NULL::"uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  v_student_id uuid;
BEGIN
  SELECT student_id INTO v_student_id FROM public.admissions WHERE id = p_admission_id;

  -- Update Student Table
  UPDATE public.students
  SET 
    name = p_student_name,
    phone_number = p_student_phone_number,
    location_id = p_location_id::integer,
    profile_data = jsonb_build_object(
      'father_name', p_father_name,
      'father_phone_number', p_father_phone_number,
      'permanent_address', p_permanent_address,
      'current_address', p_current_address,
      'identification_type', p_identification_type,
      'identification_number', p_identification_number
    )
  WHERE id = v_student_id;

  -- Update Admissions Table
  UPDATE public.admissions
  SET 
    date_of_admission = p_date_of_admission,
    course_start_date = p_course_start_date,
    batch_preference = p_batch_preference,
    remarks = p_remarks,
    certificate_id = p_certificate_id,
    discount = p_discount
    -- ✅ REMOVED: updated_at = NOW()
  WHERE id = p_admission_id;

  -- Sync Courses
  DELETE FROM public.admission_courses WHERE admission_id = p_admission_id;
  INSERT INTO public.admission_courses (admission_id, course_id)
  SELECT p_admission_id, unnest(p_course_ids);

  -- Sync Installments
  IF jsonb_array_length(p_installments) > 0 THEN
    DELETE FROM public.installments WHERE admission_id = p_admission_id;
    INSERT INTO public.installments (admission_id, amount, due_date, status)
    SELECT 
      p_admission_id, 
      (val->>'amount')::numeric, 
      (val->>'due_date')::date, 
      COALESCE(val->>'status', 'Pending')
    FROM jsonb_array_elements(p_installments) AS val;
  END IF;

  -- Audit Log remains as is
  INSERT INTO public.admission_remarks (admission_id, remark_text, created_by)
  VALUES (p_admission_id, 'Full record update sync completed', p_updated_by);
END;
$$;


ALTER FUNCTION "public"."update_admission_full"("p_admission_id" "uuid", "p_student_name" "text", "p_student_phone_number" "text", "p_father_name" "text", "p_father_phone_number" "text", "p_permanent_address" "text", "p_current_address" "text", "p_identification_type" "text", "p_identification_number" "text", "p_date_of_admission" "date", "p_course_start_date" "date", "p_batch_preference" "text", "p_remarks" "text", "p_certificate_id" "uuid", "p_discount" numeric, "p_course_ids" "uuid"[], "p_installments" "jsonb", "p_location_id" "text", "p_updated_by" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_course_with_books"("p_course_id" "uuid", "p_name" "text", "p_price" numeric, "p_book_ids" "uuid"[]) RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  book_id UUID;
BEGIN
  UPDATE public.courses
  SET name = p_name, price = p_price
  WHERE id = p_course_id;

  DELETE FROM public.course_books WHERE course_id = p_course_id;

  IF array_length(p_book_ids, 1) > 0 THEN
    FOREACH book_id IN ARRAY p_book_ids
    LOOP
      INSERT INTO public.course_books (course_id, book_id)
      VALUES (p_course_id, book_id);
    END LOOP;
  END IF;
END;
$$;


ALTER FUNCTION "public"."update_course_with_books"("p_course_id" "uuid", "p_name" "text", "p_price" numeric, "p_book_ids" "uuid"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_faculty_availability"("p_faculty_id" "uuid", "p_availability" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  -- Remove old availability
  DELETE FROM faculty_availability
  WHERE faculty_id = p_faculty_id;

  -- Insert new availability
  INSERT INTO faculty_availability (
    faculty_id,
    day_of_week,
    start_time,
    end_time
  )
  SELECT
    p_faculty_id,
    a->>'day_of_week',
    (a->>'start_time')::time,
    (a->>'end_time')::time
  FROM jsonb_array_elements(p_availability) a;
END;
$$;


ALTER FUNCTION "public"."update_faculty_availability"("p_faculty_id" "uuid", "p_availability" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_modified_column"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_modified_column"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_ticket_tracking_logic"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    -- Update the 'updated_at' timestamp on every change
    NEW.updated_at = now();

    -- LOGIC: Handle Resolution Time
    IF NEW.status = 'Resolved' AND (OLD.status IS NULL OR OLD.status != 'Resolved') THEN
        NEW.resolved_at = now();
    ELSIF NEW.status != 'Resolved' THEN
        NEW.resolved_at = NULL; -- This handles the 'REOPEN' logic automatically
    END IF;

    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_ticket_tracking_logic"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."validate_job_application_branch"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  student_branch integer;
  allowed_count integer;
  match_count integer;
BEGIN
  -- Student branch
  SELECT location_id
  INTO student_branch
  FROM students
  WHERE id = NEW.student_id;

  IF student_branch IS NULL THEN
    RAISE EXCEPTION 'Student branch not found';
  END IF;

  -- How many branches does this job allow?
  SELECT COUNT(*)
  INTO allowed_count
  FROM job_locations
  WHERE job_id = NEW.job_id;

  -- GLOBAL JOB → allow
  IF allowed_count = 0 THEN
    RETURN NEW;
  END IF;

  -- Check branch match
  SELECT COUNT(*)
  INTO match_count
  FROM job_locations
  WHERE job_id = NEW.job_id
    AND location_id = student_branch;

  IF match_count = 0 THEN
    RAISE EXCEPTION 'Job not available for your branch';
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."validate_job_application_branch"() OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."activities" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "action" character varying,
    "item" character varying,
    "user" character varying,
    "type" character varying,
    "user_id" "uuid",
    "location_id" integer NOT NULL
);


ALTER TABLE "public"."activities" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."activities_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."activities_id_seq" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."admin_branches" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "admin_id" "uuid" NOT NULL,
    "branch_id" integer NOT NULL
);


ALTER TABLE "public"."admin_branches" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."admin_notifications" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "application_id" "uuid" NOT NULL,
    "student_id" "uuid" NOT NULL,
    "message" "text" NOT NULL,
    "created_at" timestamp without time zone DEFAULT "now"(),
    "is_read" boolean DEFAULT false
);


ALTER TABLE "public"."admin_notifications" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."admission_courses" (
    "admission_id" "uuid" NOT NULL,
    "course_id" "uuid" NOT NULL
);


ALTER TABLE "public"."admission_courses" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."admission_intakes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "student_name" "text" NOT NULL,
    "student_phone_number" "text" NOT NULL,
    "father_name" "text",
    "father_phone_number" "text",
    "email" "text",
    "date_of_birth" "date",
    "date_of_joining" "date",
    "identification_type" "text",
    "identification_number" "text",
    "identification_files" "jsonb" NOT NULL,
    "course_ids" "uuid"[] NOT NULL,
    "fee_amount" numeric,
    "video_completed" boolean DEFAULT false,
    "contacts_acknowledged" boolean DEFAULT false,
    "terms_accepted" boolean DEFAULT false,
    "status" "text" DEFAULT 'submitted'::"text",
    "admission_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "current_address" "text",
    "permanent_address" "text",
    "location_id" bigint
);


ALTER TABLE "public"."admission_intakes" OWNER TO "postgres";


COMMENT ON COLUMN "public"."admission_intakes"."location_id" IS '1: Faridabad, 2: Pune, 3: Ahmedabad';



CREATE TABLE IF NOT EXISTS "public"."admission_number_counters" (
    "year" integer NOT NULL,
    "last_number" integer NOT NULL
);


ALTER TABLE "public"."admission_number_counters" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."admission_number_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."admission_number_seq" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."admission_remarks" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "admission_id" "uuid" NOT NULL,
    "remark_text" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "created_by" "text"
);


ALTER TABLE "public"."admission_remarks" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."admissions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "student_id" "uuid" NOT NULL,
    "certificate_id" "uuid",
    "base_tuition_fees" numeric(10,2) DEFAULT 0 NOT NULL,
    "total_invoice_amount" numeric(10,2) NOT NULL,
    "final_payable_amount" numeric(10,2) NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "student_name" "text",
    "student_phone_number" "text",
    "father_name" "text",
    "father_phone_number" "text",
    "current_address" "text",
    "approval_status" "text" DEFAULT 'Pending'::"text" NOT NULL,
    "date_of_admission" "date",
    "course_start_date" "date",
    "batch_preference" "text",
    "base_amount" numeric DEFAULT 0,
    "subtotal" numeric DEFAULT 0,
    "discount" numeric DEFAULT 0,
    "gst_rate" numeric DEFAULT 0,
    "is_gst_exempt" boolean DEFAULT false,
    "remarks" "text",
    "permanent_address" "text",
    "identification_type" "text",
    "identification_number" "text",
    "total_payable_amount" numeric DEFAULT 0,
    "source_intake_id" "uuid",
    "undertaking_status" "text" DEFAULT 'Pending'::"text" NOT NULL,
    "undertaking_completed" boolean DEFAULT false,
    "undertaking_completed_at" timestamp with time zone,
    "undertaking_source" "text",
    "undertaking_files" "jsonb" DEFAULT '[]'::"jsonb",
    "joined" boolean DEFAULT false,
    "location_id" integer,
    "admitted_by" "uuid",
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "is_dropout" boolean DEFAULT false,
    "dropout_reason" "text",
    "dropout_at" timestamp with time zone,
    CONSTRAINT "admissions_approval_status_check" CHECK (("approval_status" = ANY (ARRAY['Pending'::"text", 'Approved'::"text", 'Rejected'::"text"]))),
    CONSTRAINT "undertaking_status_check" CHECK (("undertaking_status" = ANY (ARRAY['Pending'::"text", 'Completed'::"text"])))
);


ALTER TABLE "public"."admissions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."announcements" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "title" "text" NOT NULL,
    "message" "text" NOT NULL,
    "scope" "text" NOT NULL,
    "batch_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "location_id" integer NOT NULL,
    CONSTRAINT "announcements_scope_check" CHECK (("scope" = ANY (ARRAY['all'::"text", 'batch'::"text"]))),
    CONSTRAINT "scope_batch_consistency" CHECK (((("scope" = 'all'::"text") AND ("batch_id" IS NULL)) OR (("scope" = 'batch'::"text") AND ("batch_id" IS NOT NULL))))
);


ALTER TABLE "public"."announcements" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."application_chats" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "application_id" "uuid",
    "sender_id" "uuid",
    "sender_student_id" "uuid",
    "message" "text" NOT NULL,
    "is_admin" boolean DEFAULT false,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "read_by_student" boolean DEFAULT false
);


ALTER TABLE "public"."application_chats" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."batch_students" (
    "batch_id" "uuid" NOT NULL,
    "student_id" "uuid" NOT NULL
);


ALTER TABLE "public"."batch_students" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."batches" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "start_date" "date",
    "end_date" "date",
    "start_time" time without time zone,
    "end_time" time without time zone,
    "faculty_id" "uuid",
    "skill_id" "uuid",
    "max_students" integer,
    "status" "text",
    "days_of_week" "text"[],
    "created_at" timestamp with time zone DEFAULT "now"(),
    "location_id" integer NOT NULL,
    "schedule" integer[] DEFAULT '{1,2,3,4,5,6}'::integer[]
);


ALTER TABLE "public"."batches" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."books" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "price" numeric(10,2) NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "books_price_check" CHECK (("price" >= (0)::numeric))
);


ALTER TABLE "public"."books" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."candidate_languages" (
    "candidate_id" "uuid" NOT NULL,
    "language_id" integer NOT NULL
);


ALTER TABLE "public"."candidate_languages" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."candidate_skills" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "candidate_id" "uuid",
    "skill_id" integer,
    "proficiency_level" "text" DEFAULT 'Intermediate'::"text"
);


ALTER TABLE "public"."candidate_skills" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."certificates" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "cost" numeric(10,2) NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "certificates_cost_check" CHECK (("cost" >= (0)::numeric))
);


ALTER TABLE "public"."certificates" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."chat_read_status" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "application_id" "uuid" NOT NULL,
    "student_id" "uuid" NOT NULL,
    "last_read_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."chat_read_status" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."configuration" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "key" "text" NOT NULL,
    "rate" numeric NOT NULL,
    "is_active" boolean DEFAULT true,
    "description" "text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."configuration" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."course_books" (
    "course_id" "uuid" NOT NULL,
    "book_id" "uuid" NOT NULL
);


ALTER TABLE "public"."course_books" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."courses" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "price" numeric(10,2) NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "courses_price_check" CHECK (("price" >= (0)::numeric))
);


ALTER TABLE "public"."courses" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."domain_skills" (
    "domain_id" integer NOT NULL,
    "skill_id" integer NOT NULL
);


ALTER TABLE "public"."domain_skills" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."education_levels" (
    "id" integer NOT NULL,
    "name" "text" NOT NULL
);


ALTER TABLE "public"."education_levels" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."education_levels_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."education_levels_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."education_levels_id_seq" OWNED BY "public"."education_levels"."id";



CREATE TABLE IF NOT EXISTS "public"."employer_profiles" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "company_name" "text",
    "contact_person_name" "text",
    "mobile_number" "text",
    "email" "text" NOT NULL,
    "gst_number" "text",
    "cin_number" "text",
    "website_url" "text",
    "company_size" "text",
    "logo_url" "text",
    "company_description" "text",
    "office_address" "text",
    "industry" "text" DEFAULT 'Mechanical Engineering'::"text",
    "is_approved" boolean DEFAULT false,
    "is_verified" boolean DEFAULT false,
    "password_hash" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "status" "text" DEFAULT 'Pending Approval'::"text",
    "reset_token" "text",
    "reset_token_expiry" timestamp with time zone,
    "headquarter_location" "text",
    "remarks" "text",
    CONSTRAINT "employer_profiles_company_size_check" CHECK (("company_size" = ANY (ARRAY['1-10 Employees'::"text", '11-50 Employees'::"text", '51-200 Employees'::"text", '201-500 Employees'::"text", '500+ Employees'::"text", '51-200'::"text"]))),
    CONSTRAINT "employer_profiles_status_check" CHECK (("status" = ANY (ARRAY['Pending Approval'::"text", 'Approved'::"text", 'Rejected'::"text", 'Active'::"text"])))
);


ALTER TABLE "public"."employer_profiles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."external_applications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "job_id" "uuid",
    "candidate_id" "uuid",
    "status" "text" DEFAULT 'Applied'::"text",
    "applied_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."external_applications" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."external_candidates" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "full_name" "text" NOT NULL,
    "email" "text" NOT NULL,
    "mobile_number" "text",
    "age" integer,
    "gender" "public"."gender_type",
    "tenth_pass_year" integer,
    "tenth_percentage" numeric(5,2),
    "twelfth_pass_year" integer,
    "twelfth_percentage" numeric(5,2),
    "ug_degree" "text",
    "ug_college" "text",
    "ug_cgpa" numeric(4,2),
    "pg_degree" "text",
    "pg_specialization" "text",
    "experience_range" "text",
    "is_currently_working" "public"."working_status_type" DEFAULT 'No'::"public"."working_status_type",
    "current_location" "text",
    "current_salary" numeric(12,2),
    "expected_salary" numeric(12,2),
    "notice_period" "public"."notice_period_type",
    "preferred_domain_id" integer,
    "preferred_role_id" integer,
    "resume_url" "text",
    "password_hash" "text",
    "is_verified" boolean DEFAULT false,
    "otp_code" "text",
    "otp_expiry" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "reset_token" "text",
    "reset_token_expiry" timestamp with time zone,
    "address" "text",
    "education_history" "jsonb" DEFAULT '[]'::"jsonb",
    "work_history" "jsonb" DEFAULT '[]'::"jsonb",
    "status" "text" DEFAULT 'Registered'::"text",
    CONSTRAINT "external_candidates_age_check" CHECK (("age" >= 18)),
    CONSTRAINT "external_candidates_experience_range_check" CHECK (("experience_range" = ANY (ARRAY['Fresher'::"text", '1-2'::"text", '2-4'::"text", '5-7'::"text", '7-10'::"text", '10+ years'::"text"])))
);


ALTER TABLE "public"."external_candidates" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."faculty" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "email" "text" NOT NULL,
    "phone_number" "text",
    "employment_type" "text",
    "is_active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "location_id" integer NOT NULL
);


ALTER TABLE "public"."faculty" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."faculty_availability" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "faculty_id" "uuid" NOT NULL,
    "day_of_week" "text" NOT NULL,
    "start_time" time without time zone NOT NULL,
    "end_time" time without time zone NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "check_start_end_times" CHECK (("start_time" < "end_time"))
);


ALTER TABLE "public"."faculty_availability" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."faculty_skills" (
    "faculty_id" "uuid" NOT NULL,
    "skill_id" "uuid" NOT NULL
);


ALTER TABLE "public"."faculty_skills" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."faculty_substitutions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "batch_id" "uuid" NOT NULL,
    "original_faculty_id" "uuid" NOT NULL,
    "substitute_faculty_id" "uuid" NOT NULL,
    "start_date" "date" NOT NULL,
    "end_date" "date" NOT NULL,
    "notes" "text"
);


ALTER TABLE "public"."faculty_substitutions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."follow_ups" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "admission_id" "uuid" NOT NULL,
    "follow_up_date" "date" NOT NULL,
    "notes" "text",
    "user_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "next_follow_up_date" "date",
    "type" "text",
    "lead_type" "text"
);


ALTER TABLE "public"."follow_ups" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."students" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "admission_number" "text" NOT NULL,
    "phone_number" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "remarks" "text",
    "location_id" integer NOT NULL,
    "profile_data" "jsonb" DEFAULT '{}'::"jsonb",
    "placement_status" "text" DEFAULT 'Job Seeker'::"text",
    "is_suspended" boolean DEFAULT false,
    "suspended_until" timestamp with time zone,
    "is_banned" boolean DEFAULT false,
    "is_defaulter" boolean DEFAULT false NOT NULL,
    "defaulter_reason" "text",
    "defaulter_marked_at" timestamp with time zone,
    "password_hash" "text",
    "resume_url" "text",
    "experience_level" "text",
    "skills" "text"[],
    "software_known" "text"[],
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."students" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."follow_up_details" AS
 SELECT "f"."id" AS "follow_up_id",
    "f"."created_at" AS "log_date",
    "f"."notes" AS "follow_up_notes",
    "f"."type" AS "follow_up_type",
    "f"."lead_type",
    "f"."next_follow_up_date",
    "f"."admission_id",
    "f"."user_id",
    "a"."student_id",
    "s"."admission_number",
    "s"."name" AS "student_name"
   FROM (("public"."follow_ups" "f"
     JOIN "public"."admissions" "a" ON (("f"."admission_id" = "a"."id")))
     JOIN "public"."students" "s" ON (("a"."student_id" = "s"."id")));


ALTER VIEW "public"."follow_up_details" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."general_chats" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "student_id" "uuid" NOT NULL,
    "message" "text" NOT NULL,
    "is_admin" boolean DEFAULT false,
    "read_by_student" boolean DEFAULT false,
    "read_by_admin" boolean DEFAULT false,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."general_chats" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."installments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "admission_id" "uuid" NOT NULL,
    "due_date" "date" NOT NULL,
    "amount" numeric(10,2) NOT NULL,
    "status" "text" DEFAULT 'Pending'::"text" NOT NULL,
    "paid_on" "date",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."installments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."job_applications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "job_id" "uuid",
    "student_id" "uuid",
    "status" "text" DEFAULT 'Applied'::"text",
    "applied_at" timestamp with time zone DEFAULT "now"(),
    "rejection_reason" "text",
    "admin_remarks" "text",
    "attendance_status" "text" DEFAULT 'Pending'::"text",
    "tags" "text"[] DEFAULT '{}'::"text"[],
    "reapply_granted" boolean DEFAULT false,
    "joining_date" "date",
    "testimonial_status" "text" DEFAULT 'No'::"text",
    CONSTRAINT "job_applications_testimonial_status_check" CHECK (("testimonial_status" = ANY (ARRAY['Yes'::"text", 'No'::"text"])))
);


ALTER TABLE "public"."job_applications" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."job_course_eligibility" (
    "job_id" "uuid" NOT NULL,
    "course_id" "uuid" NOT NULL
);


ALTER TABLE "public"."job_course_eligibility" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."job_domains" (
    "id" integer NOT NULL,
    "name" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."job_domains" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."job_domains_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."job_domains_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."job_domains_id_seq" OWNED BY "public"."job_domains"."id";



CREATE TABLE IF NOT EXISTS "public"."job_locations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "job_id" "uuid" NOT NULL,
    "location_id" integer NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."job_locations" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."job_roles" (
    "id" integer NOT NULL,
    "name" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."job_roles" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."job_roles_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."job_roles_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."job_roles_id_seq" OWNED BY "public"."job_roles"."id";



CREATE TABLE IF NOT EXISTS "public"."job_skills" (
    "job_id" "uuid" NOT NULL,
    "skill_id" integer NOT NULL
);


ALTER TABLE "public"."job_skills" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."jobs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "title" "text" NOT NULL,
    "company_name" "text" NOT NULL,
    "location" "text",
    "salary_range" "text",
    "job_type" "text",
    "description" "text",
    "tags" "text"[],
    "status" "text" DEFAULT 'Open'::"text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "interview_date" "date",
    "interview_time" time without time zone,
    "venue" "text",
    "interview_type" "text" DEFAULT 'walk_in'::"text",
    "campus_start_date" "date",
    "campus_end_date" "date",
    "max_candidates" integer,
    "required_candidates" integer DEFAULT 0,
    "eligible_courses" "text"[] DEFAULT '{}'::"text"[],
    "employment_type" "text",
    "admission_start_date" "date",
    "admission_end_date" "date",
    "application_deadline" "date",
    "preferred_skills" "text"[] DEFAULT '{}'::"text"[],
    "management_type" "text",
    "external_link" "text",
    "company_logo_url" "text",
    "employer_id" "uuid",
    "domain_id" integer,
    "role_id" integer,
    "experience_required" "text",
    "company_website" "text",
    "job_source" "text" DEFAULT 'internal'::"text",
    "vacancy_count" integer,
    "work_mode" "text" DEFAULT 'On-site'::"text",
    "education_requirements" "text"[] DEFAULT '{}'::"text"[],
    "notice_period_required" "text",
    CONSTRAINT "jobs_employment_type_check" CHECK (("employment_type" = ANY (ARRAY['Full-Time'::"text", 'Part-Time'::"text", 'Contract'::"text", 'Internship'::"text"]))),
    CONSTRAINT "jobs_job_source_check" CHECK (("job_source" = ANY (ARRAY['internal'::"text", 'external'::"text", 'linkedin'::"text", 'naukri'::"text", 'employer_portal'::"text", 'other'::"text"]))),
    CONSTRAINT "jobs_job_type_check" CHECK (("job_type" = ANY (ARRAY['internal'::"text", 'external'::"text"]))),
    CONSTRAINT "jobs_management_type_check" CHECK (("management_type" = ANY (ARRAY['rvm_managed'::"text", 'externally_managed'::"text"]))),
    CONSTRAINT "jobs_work_mode_check" CHECK (("work_mode" = ANY (ARRAY['On-site'::"text", 'Remote'::"text", 'Hybrid'::"text"])))
);


ALTER TABLE "public"."jobs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."languages" (
    "id" integer NOT NULL,
    "name" "text" NOT NULL
);


ALTER TABLE "public"."languages" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."languages_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."languages_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."languages_id_seq" OWNED BY "public"."languages"."id";



CREATE TABLE IF NOT EXISTS "public"."locations" (
    "id" integer NOT NULL,
    "name" "text" NOT NULL
);


ALTER TABLE "public"."locations" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."locations_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."locations_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."locations_id_seq" OWNED BY "public"."locations"."id";



CREATE TABLE IF NOT EXISTS "public"."messages" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "ticket_id" "uuid",
    "sender_user_id" "uuid",
    "sender_student_id" "uuid",
    "message" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."messages" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."payments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "admission_id" "uuid" NOT NULL,
    "payment_date" "date" DEFAULT CURRENT_DATE NOT NULL,
    "amount_paid" numeric(10,2) NOT NULL,
    "method" "text",
    "receipt_number" "text",
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "created_by" "uuid",
    "location_id" integer,
    CONSTRAINT "payments_amount_paid_check" CHECK (("amount_paid" > (0)::numeric))
);


ALTER TABLE "public"."payments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."receipt_counters" (
    "receipt_date" "date" NOT NULL,
    "last_number" integer DEFAULT 0 NOT NULL
);


ALTER TABLE "public"."receipt_counters" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."receipt_installments" (
    "receipt_id" "uuid" NOT NULL,
    "installment_id" "uuid" NOT NULL,
    "amount_applied" numeric(10,2) NOT NULL
);


ALTER TABLE "public"."receipt_installments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."receipts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "admission_id" "uuid" NOT NULL,
    "receipt_number" "text" NOT NULL,
    "amount_paid" numeric(10,2) NOT NULL,
    "payment_date" "date" NOT NULL,
    "payment_method" "text",
    "generated_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."receipts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."skill_tags" (
    "id" integer NOT NULL,
    "name" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."skill_tags" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."skill_tags_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."skill_tags_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."skill_tags_id_seq" OWNED BY "public"."skill_tags"."id";



CREATE TABLE IF NOT EXISTS "public"."skills" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "category" "text",
    "description" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "location_id" integer NOT NULL
);


ALTER TABLE "public"."skills" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."student_attendance" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "student_id" "uuid" NOT NULL,
    "batch_id" "uuid" NOT NULL,
    "date" "date" NOT NULL,
    "is_present" boolean NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."student_attendance" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."survey_responses" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid",
    "experience_level" "text",
    "current_domain" "text",
    "is_course_enough" "text",
    "additional_components" "text"[],
    "iit_program_interest" "text",
    "comfortable_fee" "text",
    "expected_outcome" "text"[],
    "submitted_at" timestamp with time zone DEFAULT "now"(),
    "student_id" "uuid",
    "course_preference" "text"
);


ALTER TABLE "public"."survey_responses" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."system_settings" (
    "key" "text" NOT NULL,
    "value" "jsonb",
    "description" "text",
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."system_settings" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."tickets" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "title" "text" NOT NULL,
    "description" "text" NOT NULL,
    "status" "public"."ticket_status" DEFAULT 'Open'::"public"."ticket_status",
    "priority" "public"."ticket_priority" DEFAULT 'Medium'::"public"."ticket_priority",
    "category" "text",
    "student_id" "uuid",
    "assignee_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "location_id" integer NOT NULL,
    "resolved_at" timestamp with time zone
);


ALTER TABLE "public"."tickets" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."users" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "username" "text",
    "phone_number" "text",
    "password_hash" "text" NOT NULL,
    "role" "public"."user_role",
    "faculty_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "location_id" integer NOT NULL,
    CONSTRAINT "at_least_one_login_method" CHECK ((("username" IS NOT NULL) OR ("phone_number" IS NOT NULL)))
);


ALTER TABLE "public"."users" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_admission_financial_summary" AS
 WITH "payment_calc" AS (
         SELECT "p_1"."admission_id",
            COALESCE("sum"("p_1"."amount_paid"), (0)::numeric) AS "total_paid_actual"
           FROM "public"."payments" "p_1"
          GROUP BY "p_1"."admission_id"
        ), "installment_calc" AS (
         SELECT "i"."admission_id",
            COALESCE("sum"("i"."amount"), (0)::numeric) AS "total_fees_from_installments"
           FROM "public"."installments" "i"
          GROUP BY "i"."admission_id"
        ), "follow_up_data" AS (
         SELECT "a_1"."id" AS "admission_id",
            COALESCE(( SELECT "fu"."next_follow_up_date"
                   FROM "public"."follow_ups" "fu"
                  WHERE ("fu"."admission_id" = "a_1"."id")
                  ORDER BY "fu"."created_at" DESC
                 LIMIT 1), ( SELECT "inst"."due_date"
                   FROM "public"."installments" "inst"
                  WHERE (("inst"."admission_id" = "a_1"."id") AND ("inst"."status" = ANY (ARRAY['Pending'::"text", 'Overdue'::"text"])))
                  ORDER BY "inst"."due_date"
                 LIMIT 1)) AS "next_task_due_date"
           FROM "public"."admissions" "a_1"
        ), "course_list" AS (
         SELECT "ac"."admission_id",
            "string_agg"("c"."name", ', '::"text" ORDER BY "c"."name") AS "courses_str"
           FROM ("public"."admission_courses" "ac"
             JOIN "public"."courses" "c" ON (("c"."id" = "ac"."course_id")))
          GROUP BY "ac"."admission_id"
        ), "course_ids" AS (
         SELECT "ac"."admission_id",
            "array_agg"("ac"."course_id") AS "course_ids"
           FROM "public"."admission_courses" "ac"
          GROUP BY "ac"."admission_id"
        ), "batch_list" AS (
         SELECT "bs"."student_id",
            "array_agg"("b"."name" ORDER BY "b"."name") AS "batch_names",
            "string_agg"("b"."name", ', '::"text" ORDER BY "b"."name") AS "batch_names_str"
           FROM ("public"."batch_students" "bs"
             JOIN "public"."batches" "b" ON (("b"."id" = "bs"."batch_id")))
          GROUP BY "bs"."student_id"
        ), "latest_intake" AS (
         SELECT DISTINCT ON ("admission_intakes"."admission_id") "admission_intakes"."admission_id",
            "admission_intakes"."id",
            "admission_intakes"."status"
           FROM "public"."admission_intakes"
          ORDER BY "admission_intakes"."admission_id", "admission_intakes"."created_at" DESC
        )
 SELECT "a"."id" AS "admission_id",
    "s"."id" AS "student_id",
    "s"."location_id",
    "s"."admission_number",
    "s"."name" AS "student_name",
    "s"."phone_number" AS "student_phone_number",
    "s"."profile_data",
    "s"."placement_status",
    "s"."is_suspended",
    "s"."is_banned",
    "a"."date_of_admission",
    "a"."course_start_date",
    "a"."batch_preference",
    "a"."remarks",
    "fud"."next_task_due_date",
    COALESCE("cert"."name", "cl"."courses_str", 'No Course Selected'::"text") AS "certificate_name",
    "ci"."course_ids",
    "cl"."courses_str",
    "bl"."batch_names",
    COALESCE("bl"."batch_names_str", 'Not Allotted'::"text") AS "batch_name",
    COALESCE("bl"."batch_names_str", 'Not Allotted'::"text") AS "branch",
    (COALESCE("ic"."total_fees_from_installments", "a"."final_payable_amount", "a"."total_payable_amount") + COALESCE("a"."discount", (0)::numeric)) AS "base_amount",
    COALESCE("ic"."total_fees_from_installments", "a"."final_payable_amount", "a"."total_payable_amount") AS "total_fees",
    COALESCE("ic"."total_fees_from_installments", "a"."final_payable_amount", "a"."total_payable_amount") AS "total_payable_amount",
    COALESCE("p"."total_paid_actual", (0)::numeric) AS "total_paid",
    (COALESCE("ic"."total_fees_from_installments", "a"."final_payable_amount", "a"."total_payable_amount") - COALESCE("p"."total_paid_actual", (0)::numeric)) AS "balance_due",
    (COALESCE("ic"."total_fees_from_installments", "a"."final_payable_amount", "a"."total_payable_amount") - COALESCE("p"."total_paid_actual", (0)::numeric)) AS "remaining_due",
        CASE
            WHEN ((COALESCE("ic"."total_fees_from_installments", "a"."final_payable_amount", "a"."total_payable_amount") - COALESCE("p"."total_paid_actual", (0)::numeric)) <= (0)::numeric) THEN 'Paid'::"text"
            ELSE 'Pending'::"text"
        END AS "status",
        CASE
            WHEN ("a"."undertaking_completed" = true) THEN 'Completed'::"text"
            WHEN (("ai"."id" IS NOT NULL) AND ("ai"."status" = 'submitted'::"text")) THEN 'Completed'::"text"
            ELSE 'Pending'::"text"
        END AS "undertaking_status",
    "a"."undertaking_completed",
    "a"."undertaking_completed_at",
    "a"."created_at",
    "a"."approval_status",
    "a"."joined",
    "a"."is_dropout",
    "a"."dropout_at",
    "a"."dropout_reason"
   FROM ((((((((("public"."admissions" "a"
     JOIN "public"."students" "s" ON (("s"."id" = "a"."student_id")))
     LEFT JOIN "public"."certificates" "cert" ON (("cert"."id" = "a"."certificate_id")))
     LEFT JOIN "course_list" "cl" ON (("cl"."admission_id" = "a"."id")))
     LEFT JOIN "course_ids" "ci" ON (("ci"."admission_id" = "a"."id")))
     LEFT JOIN "payment_calc" "p" ON (("p"."admission_id" = "a"."id")))
     LEFT JOIN "installment_calc" "ic" ON (("ic"."admission_id" = "a"."id")))
     LEFT JOIN "follow_up_data" "fud" ON (("fud"."admission_id" = "a"."id")))
     LEFT JOIN "latest_intake" "ai" ON (("ai"."admission_id" = "a"."id")))
     LEFT JOIN "batch_list" "bl" ON (("bl"."student_id" = "s"."id")));


ALTER VIEW "public"."v_admission_financial_summary" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_admission_undertaking_status" AS
 SELECT "a"."id" AS "admission_id",
        CASE
            WHEN (("ai"."admission_id" IS NOT NULL) AND ("ai"."video_completed" = true) AND ("ai"."contacts_acknowledged" = true) AND ("ai"."terms_accepted" = true)) THEN 'Completed'::"text"
            ELSE 'Pending'::"text"
        END AS "undertaking_status"
   FROM ("public"."admissions" "a"
     LEFT JOIN "public"."admission_intakes" "ai" ON (("ai"."admission_id" = "a"."id")));


ALTER VIEW "public"."v_admission_undertaking_status" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_follow_up_task_list" AS
 WITH "student_batches" AS (
         SELECT "bs"."student_id",
            "string_agg"("b"."name", ', '::"text" ORDER BY "b"."name") AS "batch_names"
           FROM ("public"."batch_students" "bs"
             JOIN "public"."batches" "b" ON (("b"."id" = "bs"."batch_id")))
          GROUP BY "bs"."student_id"
        ), "last_follow_up" AS (
         SELECT DISTINCT ON ("fu"."admission_id") "fu"."admission_id",
            "u"."username" AS "last_staff_name"
           FROM ("public"."follow_ups" "fu"
             LEFT JOIN "public"."users" "u" ON (("fu"."user_id" = "u"."id")))
          ORDER BY "fu"."admission_id", "fu"."created_at" DESC
        )
 SELECT "a"."id" AS "admission_id",
    "a"."student_id",
    "s"."location_id",
    "s"."admission_number",
    "s"."name" AS "student_name",
    "s"."phone_number" AS "student_phone",
    COALESCE("sb"."batch_names", 'Not Allotted'::"text") AS "batch_name",
    COALESCE(( SELECT "fu"."next_follow_up_date"
           FROM "public"."follow_ups" "fu"
          WHERE ("fu"."admission_id" = "a"."id")
          ORDER BY "fu"."created_at" DESC
         LIMIT 1), ( SELECT "inst"."due_date"
           FROM "public"."installments" "inst"
          WHERE (("inst"."admission_id" = "a"."id") AND ("inst"."status" = ANY (ARRAY['Pending'::"text", 'Overdue'::"text"])))
          ORDER BY "inst"."due_date"
         LIMIT 1)) AS "next_task_due_date",
    ( SELECT "count"(*) AS "count"
           FROM "public"."follow_ups" "fu"
          WHERE ("fu"."admission_id" = "a"."id")) AS "task_count",
    (COALESCE(( SELECT "sum"("i"."amount") AS "sum"
           FROM "public"."installments" "i"
          WHERE ("i"."admission_id" = "a"."id")), (0)::numeric) - COALESCE(( SELECT "sum"("p"."amount_paid") AS "sum"
           FROM "public"."payments" "p"
          WHERE ("p"."admission_id" = "a"."id")), (0)::numeric)) AS "total_due",
    (COALESCE(( SELECT "sum"("i"."amount") AS "sum"
           FROM "public"."installments" "i"
          WHERE ("i"."admission_id" = "a"."id")), (0)::numeric) - COALESCE(( SELECT "sum"("p"."amount_paid") AS "sum"
           FROM "public"."payments" "p"
          WHERE ("p"."admission_id" = "a"."id")), (0)::numeric)) AS "total_due_amount",
    ( SELECT "max"("fu"."created_at") AS "max"
           FROM "public"."follow_ups" "fu"
          WHERE ("fu"."admission_id" = "a"."id")) AS "last_log_created_at",
    COALESCE("lfu"."last_staff_name", 'System'::"text") AS "assigned_to",
    "a"."joined",
    "a"."is_dropout"
   FROM ((("public"."admissions" "a"
     JOIN "public"."students" "s" ON (("a"."student_id" = "s"."id")))
     LEFT JOIN "student_batches" "sb" ON (("sb"."student_id" = "s"."id")))
     LEFT JOIN "last_follow_up" "lfu" ON (("lfu"."admission_id" = "a"."id")));


ALTER VIEW "public"."v_follow_up_task_list" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_installment_status" AS
 WITH "payment_summaries" AS (
         SELECT "payments"."admission_id",
            "sum"("payments"."amount_paid") AS "total_student_paid"
           FROM "public"."payments"
          GROUP BY "payments"."admission_id"
        ), "cumulative_installments" AS (
         SELECT "installments"."id",
            "installments"."admission_id",
            "installments"."due_date",
            "installments"."amount" AS "amount_due",
            "sum"("installments"."amount") OVER (PARTITION BY "installments"."admission_id" ORDER BY "installments"."due_date", "installments"."id") AS "cumulative_required"
           FROM "public"."installments"
        )
 SELECT "ci"."id",
    "ci"."admission_id",
    "ci"."due_date",
    "ci"."amount_due",
        CASE
            WHEN (COALESCE("ps"."total_student_paid", (0)::numeric) >= "ci"."cumulative_required") THEN 'Paid'::"text"
            WHEN ("ci"."due_date" < CURRENT_DATE) THEN 'Overdue'::"text"
            ELSE 'Pending'::"text"
        END AS "status",
        CASE
            WHEN (COALESCE("ps"."total_student_paid", (0)::numeric) >= "ci"."cumulative_required") THEN 'Paid'::"text"
            WHEN ("ci"."due_date" < CURRENT_DATE) THEN 'Overdue'::"text"
            ELSE 'Pending'::"text"
        END AS "current_status",
    (
        CASE
            WHEN (COALESCE("ps"."total_student_paid", (0)::numeric) >= "ci"."cumulative_required") THEN 0.00
            WHEN (COALESCE("ps"."total_student_paid", (0)::numeric) > ("ci"."cumulative_required" - "ci"."amount_due")) THEN ("ci"."cumulative_required" - COALESCE("ps"."total_student_paid", (0)::numeric))
            ELSE "ci"."amount_due"
        END)::numeric(10,2) AS "balance_due"
   FROM ("cumulative_installments" "ci"
     LEFT JOIN "payment_summaries" "ps" ON (("ci"."admission_id" = "ps"."admission_id")));


ALTER VIEW "public"."v_installment_status" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_installments_with_location" AS
 SELECT "i"."id" AS "installment_id",
    "i"."admission_id",
    "i"."due_date",
    "i"."amount",
    "i"."status",
    "i"."paid_on",
    "i"."created_at",
    "s"."location_id"
   FROM (("public"."installments" "i"
     JOIN "public"."admissions" "a" ON (("i"."admission_id" = "a"."id")))
     JOIN "public"."students" "s" ON (("a"."student_id" = "s"."id")));


ALTER VIEW "public"."v_installments_with_location" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_payments_with_location" AS
 SELECT "p"."id",
    "p"."receipt_number",
    "p"."payment_date",
    "p"."amount_paid",
    "p"."method",
    "p"."notes",
    "p"."created_by",
    "u"."username" AS "created_by_username",
    "s"."admission_number",
    "s"."name" AS "student_name",
    "s"."phone_number" AS "student_phone_number",
    "a"."is_dropout",
    "s"."location_id",
    "l"."name" AS "location_name"
   FROM (((("public"."payments" "p"
     JOIN "public"."admissions" "a" ON (("p"."admission_id" = "a"."id")))
     JOIN "public"."students" "s" ON (("a"."student_id" = "s"."id")))
     JOIN "public"."locations" "l" ON (("s"."location_id" = "l"."id")))
     LEFT JOIN "public"."users" "u" ON (("p"."created_by" = "u"."id")));


ALTER VIEW "public"."v_payments_with_location" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_student_placement_metrics" AS
 SELECT "id",
    "name" AS "student_name",
    "phone_number",
    "admission_number",
    ( SELECT "count"(DISTINCT "j"."id") AS "count"
           FROM ((("public"."jobs" "j"
             JOIN "public"."job_course_eligibility" "jce" ON (("j"."id" = "jce"."job_id")))
             JOIN "public"."admission_courses" "ac" ON (("jce"."course_id" = "ac"."course_id")))
             JOIN "public"."admissions" "a" ON (("ac"."admission_id" = "a"."id")))
          WHERE (("a"."student_id" = "s"."id") AND ("j"."status" = 'Open'::"text"))) AS "total_eligible_jobs",
    ( SELECT "count"(*) AS "count"
           FROM "public"."job_applications" "ja"
          WHERE ("ja"."student_id" = "s"."id")) AS "total_applied",
    ( SELECT "count"(*) AS "count"
           FROM "public"."job_applications" "ja"
          WHERE (("ja"."student_id" = "s"."id") AND ("ja"."status" = 'No_Show'::"text"))) AS "no_show_count",
    ( SELECT "count"(*) AS "count"
           FROM "public"."job_applications" "ja"
          WHERE (("ja"."student_id" = "s"."id") AND ("ja"."status" = ANY (ARRAY['Interviewed'::"text", 'Round_2'::"text", 'Selected'::"text", 'Rejected'::"text", 'Offer_Declined'::"text", 'Left_During_Probation'::"text"])))) AS "interviews_sat"
   FROM "public"."students" "s";


ALTER VIEW "public"."v_student_placement_metrics" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_students_with_followup" AS
 WITH "installment_totals" AS (
         SELECT "installments"."admission_id",
            COALESCE("sum"("installments"."amount"), (0)::numeric) AS "total_fees"
           FROM "public"."installments"
          GROUP BY "installments"."admission_id"
        ), "payment_totals" AS (
         SELECT "payments"."admission_id",
            COALESCE("sum"("payments"."amount_paid"), (0)::numeric) AS "total_paid"
           FROM "public"."payments"
          GROUP BY "payments"."admission_id"
        ), "financials" AS (
         SELECT "a_1"."id" AS "admission_id",
            (COALESCE("i"."total_fees", (0)::numeric) - COALESCE("p"."total_paid", (0)::numeric)) AS "total_due_amount"
           FROM (("public"."admissions" "a_1"
             LEFT JOIN "installment_totals" "i" ON (("i"."admission_id" = "a_1"."id")))
             LEFT JOIN "payment_totals" "p" ON (("p"."admission_id" = "a_1"."id")))
        )
 SELECT "s"."id",
    "s"."name",
    "s"."admission_number",
    "s"."phone_number",
    "s"."location_id",
        CASE
            WHEN ("s"."is_defaulter" = true) THEN 'DEFAULTER'::"text"
            WHEN ("f"."total_due_amount" <= (0)::numeric) THEN 'FULL PAID'::"text"
            WHEN ("vft"."next_task_due_date" IS NOT NULL) THEN "to_char"(("vft"."next_task_due_date")::timestamp with time zone, 'DD Mon YYYY'::"text")
            ELSE "s"."remarks"
        END AS "remarks",
    "s"."is_defaulter",
    "f"."total_due_amount",
    "s"."created_at",
    "s"."updated_at"
   FROM ((("public"."students" "s"
     LEFT JOIN "public"."admissions" "a" ON (("a"."student_id" = "s"."id")))
     LEFT JOIN "financials" "f" ON (("f"."admission_id" = "a"."id")))
     LEFT JOIN "public"."v_follow_up_task_list" "vft" ON (("vft"."admission_id" = "a"."id")));


ALTER VIEW "public"."v_students_with_followup" OWNER TO "postgres";


ALTER TABLE ONLY "public"."education_levels" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."education_levels_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."job_domains" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."job_domains_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."job_roles" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."job_roles_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."languages" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."languages_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."locations" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."locations_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."skill_tags" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."skill_tags_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."activities"
    ADD CONSTRAINT "activities_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."admin_branches"
    ADD CONSTRAINT "admin_branches_admin_id_branch_id_key" UNIQUE ("admin_id", "branch_id");



ALTER TABLE ONLY "public"."admin_branches"
    ADD CONSTRAINT "admin_branches_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."admin_notifications"
    ADD CONSTRAINT "admin_notifications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."admission_courses"
    ADD CONSTRAINT "admission_courses_pkey" PRIMARY KEY ("admission_id", "course_id");



ALTER TABLE ONLY "public"."admission_intakes"
    ADD CONSTRAINT "admission_intakes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."admission_number_counters"
    ADD CONSTRAINT "admission_number_counters_pkey" PRIMARY KEY ("year");



ALTER TABLE ONLY "public"."admission_remarks"
    ADD CONSTRAINT "admission_remarks_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."admissions"
    ADD CONSTRAINT "admissions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."announcements"
    ADD CONSTRAINT "announcements_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."application_chats"
    ADD CONSTRAINT "application_chats_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."batch_students"
    ADD CONSTRAINT "batch_students_pkey" PRIMARY KEY ("batch_id", "student_id");



ALTER TABLE ONLY "public"."batches"
    ADD CONSTRAINT "batches_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."books"
    ADD CONSTRAINT "books_name_key" UNIQUE ("name");



ALTER TABLE ONLY "public"."books"
    ADD CONSTRAINT "books_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."candidate_languages"
    ADD CONSTRAINT "candidate_languages_pkey" PRIMARY KEY ("candidate_id", "language_id");



ALTER TABLE ONLY "public"."candidate_skills"
    ADD CONSTRAINT "candidate_skills_candidate_id_skill_id_key" UNIQUE ("candidate_id", "skill_id");



ALTER TABLE ONLY "public"."candidate_skills"
    ADD CONSTRAINT "candidate_skills_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."certificates"
    ADD CONSTRAINT "certificates_name_key" UNIQUE ("name");



ALTER TABLE ONLY "public"."certificates"
    ADD CONSTRAINT "certificates_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."chat_read_status"
    ADD CONSTRAINT "chat_read_status_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."configuration"
    ADD CONSTRAINT "configuration_key_key" UNIQUE ("key");



ALTER TABLE ONLY "public"."configuration"
    ADD CONSTRAINT "configuration_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."course_books"
    ADD CONSTRAINT "course_books_pkey" PRIMARY KEY ("course_id", "book_id");



ALTER TABLE ONLY "public"."courses"
    ADD CONSTRAINT "courses_name_key" UNIQUE ("name");



ALTER TABLE ONLY "public"."courses"
    ADD CONSTRAINT "courses_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."domain_skills"
    ADD CONSTRAINT "domain_skills_pkey" PRIMARY KEY ("domain_id", "skill_id");



ALTER TABLE ONLY "public"."education_levels"
    ADD CONSTRAINT "education_levels_name_key" UNIQUE ("name");



ALTER TABLE ONLY "public"."education_levels"
    ADD CONSTRAINT "education_levels_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."employer_profiles"
    ADD CONSTRAINT "employer_mobile_unique" UNIQUE ("mobile_number");



ALTER TABLE ONLY "public"."employer_profiles"
    ADD CONSTRAINT "employer_profiles_email_key" UNIQUE ("email");



ALTER TABLE ONLY "public"."employer_profiles"
    ADD CONSTRAINT "employer_profiles_email_unique" UNIQUE ("email");



ALTER TABLE ONLY "public"."employer_profiles"
    ADD CONSTRAINT "employer_profiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."external_applications"
    ADD CONSTRAINT "external_applications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."external_candidates"
    ADD CONSTRAINT "external_candidates_email_key" UNIQUE ("email");



ALTER TABLE ONLY "public"."external_candidates"
    ADD CONSTRAINT "external_candidates_mobile_number_key" UNIQUE ("mobile_number");



ALTER TABLE ONLY "public"."external_candidates"
    ADD CONSTRAINT "external_candidates_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."faculty_availability"
    ADD CONSTRAINT "faculty_availability_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."faculty"
    ADD CONSTRAINT "faculty_email_location_key" UNIQUE ("email", "location_id");



ALTER TABLE ONLY "public"."faculty"
    ADD CONSTRAINT "faculty_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."faculty_skills"
    ADD CONSTRAINT "faculty_skills_pkey" PRIMARY KEY ("faculty_id", "skill_id");



ALTER TABLE ONLY "public"."faculty_substitutions"
    ADD CONSTRAINT "faculty_substitutions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."follow_ups"
    ADD CONSTRAINT "follow_ups_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."general_chats"
    ADD CONSTRAINT "general_chats_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."installments"
    ADD CONSTRAINT "installments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."job_applications"
    ADD CONSTRAINT "job_applications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."job_course_eligibility"
    ADD CONSTRAINT "job_course_eligibility_pkey" PRIMARY KEY ("job_id", "course_id");



ALTER TABLE ONLY "public"."job_domains"
    ADD CONSTRAINT "job_domains_name_key" UNIQUE ("name");



ALTER TABLE ONLY "public"."job_domains"
    ADD CONSTRAINT "job_domains_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."job_locations"
    ADD CONSTRAINT "job_locations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."job_locations"
    ADD CONSTRAINT "job_locations_unique" UNIQUE ("job_id", "location_id");



ALTER TABLE ONLY "public"."job_roles"
    ADD CONSTRAINT "job_roles_name_key" UNIQUE ("name");



ALTER TABLE ONLY "public"."job_roles"
    ADD CONSTRAINT "job_roles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."job_skills"
    ADD CONSTRAINT "job_skills_pkey" PRIMARY KEY ("job_id", "skill_id");



ALTER TABLE ONLY "public"."jobs"
    ADD CONSTRAINT "jobs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."languages"
    ADD CONSTRAINT "languages_name_key" UNIQUE ("name");



ALTER TABLE ONLY "public"."languages"
    ADD CONSTRAINT "languages_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."locations"
    ADD CONSTRAINT "locations_name_key" UNIQUE ("name");



ALTER TABLE ONLY "public"."locations"
    ADD CONSTRAINT "locations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."messages"
    ADD CONSTRAINT "messages_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."payments"
    ADD CONSTRAINT "payments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."receipt_counters"
    ADD CONSTRAINT "receipt_counters_pkey" PRIMARY KEY ("receipt_date");



ALTER TABLE ONLY "public"."receipt_installments"
    ADD CONSTRAINT "receipt_installments_pkey" PRIMARY KEY ("receipt_id", "installment_id");



ALTER TABLE ONLY "public"."receipts"
    ADD CONSTRAINT "receipts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."receipts"
    ADD CONSTRAINT "receipts_receipt_number_key" UNIQUE ("receipt_number");



ALTER TABLE ONLY "public"."skill_tags"
    ADD CONSTRAINT "skill_tags_name_key" UNIQUE ("name");



ALTER TABLE ONLY "public"."skill_tags"
    ADD CONSTRAINT "skill_tags_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."skills"
    ADD CONSTRAINT "skills_name_location_key" UNIQUE ("name", "location_id");



ALTER TABLE ONLY "public"."skills"
    ADD CONSTRAINT "skills_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."student_attendance"
    ADD CONSTRAINT "student_attendance_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."student_attendance"
    ADD CONSTRAINT "student_attendance_unique" UNIQUE ("batch_id", "student_id", "date");



ALTER TABLE ONLY "public"."students"
    ADD CONSTRAINT "students_admission_number_location_key" UNIQUE ("admission_number", "location_id");



ALTER TABLE ONLY "public"."students"
    ADD CONSTRAINT "students_phone_number_unique" UNIQUE ("phone_number");



ALTER TABLE ONLY "public"."students"
    ADD CONSTRAINT "students_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."survey_responses"
    ADD CONSTRAINT "survey_responses_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."survey_responses"
    ADD CONSTRAINT "survey_responses_student_id_unique" UNIQUE ("student_id");



ALTER TABLE ONLY "public"."system_settings"
    ADD CONSTRAINT "system_settings_pkey" PRIMARY KEY ("key");



ALTER TABLE ONLY "public"."ticket_chats"
    ADD CONSTRAINT "ticket_chats_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."tickets"
    ADD CONSTRAINT "tickets_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."external_applications"
    ADD CONSTRAINT "unique_candidate_per_job" UNIQUE ("job_id", "candidate_id");



ALTER TABLE ONLY "public"."external_applications"
    ADD CONSTRAINT "unique_job_candidate" UNIQUE ("job_id", "candidate_id");



ALTER TABLE ONLY "public"."admissions"
    ADD CONSTRAINT "unique_source_intake" UNIQUE ("source_intake_id");



ALTER TABLE ONLY "public"."admissions"
    ADD CONSTRAINT "unique_student_admission" UNIQUE ("student_id");



ALTER TABLE ONLY "public"."job_applications"
    ADD CONSTRAINT "unique_student_job_entry" UNIQUE ("student_id", "job_id");



ALTER TABLE ONLY "public"."faculty_substitutions"
    ADD CONSTRAINT "unique_substitution_period" EXCLUDE USING "gist" ("batch_id" WITH =, "daterange"("start_date", "end_date", '[]'::"text") WITH &&);



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_phone_number_location_key" UNIQUE ("phone_number", "location_id");



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_username_location_key" UNIQUE ("username", "location_id");



CREATE INDEX "idx_admission_remarks_admission_id" ON "public"."admission_remarks" USING "btree" ("admission_id");



CREATE INDEX "idx_admissions_is_dropout" ON "public"."admissions" USING "btree" ("is_dropout");



CREATE INDEX "idx_admissions_location_id" ON "public"."admissions" USING "btree" ("location_id");



CREATE INDEX "idx_admissions_student_id" ON "public"."admissions" USING "btree" ("student_id");



CREATE INDEX "idx_announcements_batch_id" ON "public"."announcements" USING "btree" ("batch_id");



CREATE INDEX "idx_announcements_created_at" ON "public"."announcements" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_announcements_location_id" ON "public"."announcements" USING "btree" ("location_id");



CREATE INDEX "idx_announcements_scope" ON "public"."announcements" USING "btree" ("scope");



CREATE INDEX "idx_application_chats_unread" ON "public"."application_chats" USING "btree" ("application_id", "is_admin");



CREATE INDEX "idx_batch_students_batch_id" ON "public"."batch_students" USING "btree" ("batch_id");



CREATE INDEX "idx_batch_students_student_id" ON "public"."batch_students" USING "btree" ("student_id");



CREATE INDEX "idx_course_books_book_id" ON "public"."course_books" USING "btree" ("book_id");



CREATE INDEX "idx_course_books_course_id" ON "public"."course_books" USING "btree" ("course_id");



CREATE INDEX "idx_employer_approval" ON "public"."employer_profiles" USING "btree" ("is_approved");



CREATE INDEX "idx_employer_email" ON "public"."employer_profiles" USING "btree" ("email");



CREATE INDEX "idx_ext_apps_candidate" ON "public"."external_applications" USING "btree" ("candidate_id");



CREATE INDEX "idx_ext_apps_job" ON "public"."external_applications" USING "btree" ("job_id");



CREATE INDEX "idx_faculty_availability_faculty_id" ON "public"."faculty_availability" USING "btree" ("faculty_id");



CREATE INDEX "idx_faculty_skills_faculty_id" ON "public"."faculty_skills" USING "btree" ("faculty_id");



CREATE INDEX "idx_faculty_skills_skill_id" ON "public"."faculty_skills" USING "btree" ("skill_id");



CREATE INDEX "idx_faculty_substitutions_batch_id" ON "public"."faculty_substitutions" USING "btree" ("batch_id");



CREATE INDEX "idx_installments_admission_id" ON "public"."installments" USING "btree" ("admission_id");



CREATE INDEX "idx_job_locations_job_id" ON "public"."job_locations" USING "btree" ("job_id");



CREATE INDEX "idx_job_locations_location_id" ON "public"."job_locations" USING "btree" ("location_id");



CREATE INDEX "idx_jobs_id_metadata" ON "public"."jobs" USING "btree" ("id", "management_type", "external_link");



CREATE INDEX "idx_student_attendance_batch_id" ON "public"."student_attendance" USING "btree" ("batch_id");



CREATE INDEX "idx_student_attendance_student_id" ON "public"."student_attendance" USING "btree" ("student_id");



CREATE INDEX "idx_students_placement_status" ON "public"."students" USING "btree" ("placement_status");



CREATE INDEX "idx_ticket_chats_ticket_id" ON "public"."ticket_chats" USING "btree" ("ticket_id");



CREATE INDEX "idx_tickets_assignee_id" ON "public"."tickets" USING "btree" ("assignee_id");



CREATE INDEX "idx_tickets_location_id" ON "public"."tickets" USING "btree" ("location_id");



CREATE INDEX "idx_tickets_priority" ON "public"."tickets" USING "btree" ("priority");



CREATE INDEX "idx_tickets_status" ON "public"."tickets" USING "btree" ("status");



CREATE INDEX "idx_tickets_student_id" ON "public"."tickets" USING "btree" ("student_id");



CREATE UNIQUE INDEX "uniq_job_student" ON "public"."job_applications" USING "btree" ("job_id", "student_id");



CREATE OR REPLACE TRIGGER "enforce_admin_assignee_on_tickets" BEFORE INSERT OR UPDATE ON "public"."tickets" FOR EACH ROW EXECUTE FUNCTION "public"."check_assignee_is_admin"();



CREATE OR REPLACE TRIGGER "tr_sync_location_only" AFTER UPDATE OF "location_id" ON "public"."students" FOR EACH ROW EXECUTE FUNCTION "public"."fn_sync_student_location_to_admissions"();



CREATE OR REPLACE TRIGGER "tr_sync_student_to_admissions" AFTER UPDATE OF "name", "phone_number", "location_id" ON "public"."students" FOR EACH ROW EXECUTE FUNCTION "public"."fn_sync_student_changes_to_admissions"();



CREATE OR REPLACE TRIGGER "trg_auto_reset_reapply" BEFORE UPDATE ON "public"."job_applications" FOR EACH ROW EXECUTE FUNCTION "public"."reset_status_on_reapply"();



CREATE OR REPLACE TRIGGER "trg_mark_intake_converted" AFTER INSERT ON "public"."admissions" FOR EACH ROW WHEN (("new"."source_intake_id" IS NOT NULL)) EXECUTE FUNCTION "public"."mark_intake_converted"();



CREATE OR REPLACE TRIGGER "trg_set_tickets_tracking" BEFORE UPDATE ON "public"."tickets" FOR EACH ROW EXECUTE FUNCTION "public"."update_ticket_tracking_logic"();



CREATE OR REPLACE TRIGGER "trg_sync_admission_location" BEFORE INSERT ON "public"."admissions" FOR EACH ROW EXECUTE FUNCTION "public"."sync_admission_location"();



CREATE OR REPLACE TRIGGER "trg_sync_batch_schedule" BEFORE INSERT OR UPDATE ON "public"."batches" FOR EACH ROW EXECUTE FUNCTION "public"."sync_batch_schedule"();



CREATE OR REPLACE TRIGGER "trg_validate_job_application_branch" BEFORE INSERT ON "public"."job_applications" FOR EACH ROW EXECUTE FUNCTION "public"."validate_job_application_branch"();



CREATE OR REPLACE TRIGGER "update_student_modtime" BEFORE UPDATE ON "public"."students" FOR EACH ROW EXECUTE FUNCTION "public"."update_modified_column"();



ALTER TABLE ONLY "public"."activities"
    ADD CONSTRAINT "activities_location_id_fkey" FOREIGN KEY ("location_id") REFERENCES "public"."locations"("id");



ALTER TABLE ONLY "public"."activities"
    ADD CONSTRAINT "activities_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id");



ALTER TABLE ONLY "public"."admin_branches"
    ADD CONSTRAINT "admin_branches_admin_id_fkey" FOREIGN KEY ("admin_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."admin_branches"
    ADD CONSTRAINT "admin_branches_branch_id_fkey" FOREIGN KEY ("branch_id") REFERENCES "public"."locations"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."admin_notifications"
    ADD CONSTRAINT "admin_notifications_application_id_fkey" FOREIGN KEY ("application_id") REFERENCES "public"."job_applications"("id");



ALTER TABLE ONLY "public"."admin_notifications"
    ADD CONSTRAINT "admin_notifications_student_id_fkey" FOREIGN KEY ("student_id") REFERENCES "public"."students"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."admission_courses"
    ADD CONSTRAINT "admission_courses_admission_id_fkey" FOREIGN KEY ("admission_id") REFERENCES "public"."admissions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."admission_courses"
    ADD CONSTRAINT "admission_courses_course_id_fkey" FOREIGN KEY ("course_id") REFERENCES "public"."courses"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."admission_intakes"
    ADD CONSTRAINT "admission_intakes_admission_id_fkey" FOREIGN KEY ("admission_id") REFERENCES "public"."admissions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."admission_intakes"
    ADD CONSTRAINT "admission_intakes_location_id_fkey" FOREIGN KEY ("location_id") REFERENCES "public"."locations"("id");



ALTER TABLE ONLY "public"."admission_remarks"
    ADD CONSTRAINT "admission_remarks_admission_id_fkey" FOREIGN KEY ("admission_id") REFERENCES "public"."admissions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."admissions"
    ADD CONSTRAINT "admissions_admitted_by_fkey" FOREIGN KEY ("admitted_by") REFERENCES "public"."users"("id");



ALTER TABLE ONLY "public"."admissions"
    ADD CONSTRAINT "admissions_location_id_fkey" FOREIGN KEY ("location_id") REFERENCES "public"."locations"("id");



ALTER TABLE ONLY "public"."admissions"
    ADD CONSTRAINT "admissions_student_id_fkey" FOREIGN KEY ("student_id") REFERENCES "public"."students"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."announcements"
    ADD CONSTRAINT "announcements_batch_id_fkey" FOREIGN KEY ("batch_id") REFERENCES "public"."batches"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."announcements"
    ADD CONSTRAINT "announcements_location_id_fkey" FOREIGN KEY ("location_id") REFERENCES "public"."locations"("id");



ALTER TABLE ONLY "public"."application_chats"
    ADD CONSTRAINT "application_chats_application_id_fkey" FOREIGN KEY ("application_id") REFERENCES "public"."job_applications"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."application_chats"
    ADD CONSTRAINT "application_chats_sender_id_fkey" FOREIGN KEY ("sender_id") REFERENCES "public"."users"("id");



ALTER TABLE ONLY "public"."application_chats"
    ADD CONSTRAINT "application_chats_sender_student_id_fkey" FOREIGN KEY ("sender_student_id") REFERENCES "public"."students"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."batch_students"
    ADD CONSTRAINT "batch_students_batch_id_fkey" FOREIGN KEY ("batch_id") REFERENCES "public"."batches"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."batch_students"
    ADD CONSTRAINT "batch_students_student_id_fkey" FOREIGN KEY ("student_id") REFERENCES "public"."students"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."batches"
    ADD CONSTRAINT "batches_faculty_id_fkey" FOREIGN KEY ("faculty_id") REFERENCES "public"."faculty"("id");



ALTER TABLE ONLY "public"."batches"
    ADD CONSTRAINT "batches_location_id_fkey" FOREIGN KEY ("location_id") REFERENCES "public"."locations"("id");



ALTER TABLE ONLY "public"."batches"
    ADD CONSTRAINT "batches_skill_id_fkey" FOREIGN KEY ("skill_id") REFERENCES "public"."skills"("id");



ALTER TABLE ONLY "public"."candidate_languages"
    ADD CONSTRAINT "candidate_languages_candidate_id_fkey" FOREIGN KEY ("candidate_id") REFERENCES "public"."external_candidates"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."candidate_languages"
    ADD CONSTRAINT "candidate_languages_language_id_fkey" FOREIGN KEY ("language_id") REFERENCES "public"."languages"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."candidate_skills"
    ADD CONSTRAINT "candidate_skills_candidate_id_fkey" FOREIGN KEY ("candidate_id") REFERENCES "public"."external_candidates"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."candidate_skills"
    ADD CONSTRAINT "candidate_skills_skill_id_fkey" FOREIGN KEY ("skill_id") REFERENCES "public"."skill_tags"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."chat_read_status"
    ADD CONSTRAINT "chat_read_status_application_id_fkey" FOREIGN KEY ("application_id") REFERENCES "public"."job_applications"("id");



ALTER TABLE ONLY "public"."chat_read_status"
    ADD CONSTRAINT "chat_read_status_student_id_fkey" FOREIGN KEY ("student_id") REFERENCES "public"."students"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."messages"
    ADD CONSTRAINT "chk_one_sender" FOREIGN KEY ("sender_user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."course_books"
    ADD CONSTRAINT "course_books_book_id_fkey" FOREIGN KEY ("book_id") REFERENCES "public"."books"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."course_books"
    ADD CONSTRAINT "course_books_course_id_fkey" FOREIGN KEY ("course_id") REFERENCES "public"."courses"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."domain_skills"
    ADD CONSTRAINT "domain_skills_domain_id_fkey" FOREIGN KEY ("domain_id") REFERENCES "public"."job_domains"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."domain_skills"
    ADD CONSTRAINT "domain_skills_skill_id_fkey" FOREIGN KEY ("skill_id") REFERENCES "public"."skill_tags"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."external_applications"
    ADD CONSTRAINT "external_applications_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."jobs"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."external_candidates"
    ADD CONSTRAINT "external_candidates_preferred_domain_id_fkey" FOREIGN KEY ("preferred_domain_id") REFERENCES "public"."job_domains"("id");



ALTER TABLE ONLY "public"."external_candidates"
    ADD CONSTRAINT "external_candidates_preferred_role_id_fkey" FOREIGN KEY ("preferred_role_id") REFERENCES "public"."job_roles"("id");



ALTER TABLE ONLY "public"."faculty_availability"
    ADD CONSTRAINT "faculty_availability_faculty_id_fkey" FOREIGN KEY ("faculty_id") REFERENCES "public"."faculty"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."faculty"
    ADD CONSTRAINT "faculty_location_id_fkey" FOREIGN KEY ("location_id") REFERENCES "public"."locations"("id");



ALTER TABLE ONLY "public"."faculty_skills"
    ADD CONSTRAINT "faculty_skills_faculty_id_fkey" FOREIGN KEY ("faculty_id") REFERENCES "public"."faculty"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."faculty_skills"
    ADD CONSTRAINT "faculty_skills_skill_id_fkey" FOREIGN KEY ("skill_id") REFERENCES "public"."skills"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."faculty_substitutions"
    ADD CONSTRAINT "faculty_substitutions_batch_id_fkey" FOREIGN KEY ("batch_id") REFERENCES "public"."batches"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."faculty_substitutions"
    ADD CONSTRAINT "faculty_substitutions_original_faculty_id_fkey" FOREIGN KEY ("original_faculty_id") REFERENCES "public"."faculty"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."faculty_substitutions"
    ADD CONSTRAINT "faculty_substitutions_substitute_faculty_id_fkey" FOREIGN KEY ("substitute_faculty_id") REFERENCES "public"."faculty"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."payments"
    ADD CONSTRAINT "fk_payments_created_by" FOREIGN KEY ("created_by") REFERENCES "public"."users"("id");



ALTER TABLE ONLY "public"."general_chats"
    ADD CONSTRAINT "general_chats_student_id_fkey" FOREIGN KEY ("student_id") REFERENCES "public"."students"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."installments"
    ADD CONSTRAINT "installments_admission_id_fkey" FOREIGN KEY ("admission_id") REFERENCES "public"."admissions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."job_applications"
    ADD CONSTRAINT "job_applications_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."jobs"("id");



ALTER TABLE ONLY "public"."job_applications"
    ADD CONSTRAINT "job_applications_student_id_fkey" FOREIGN KEY ("student_id") REFERENCES "public"."students"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."job_course_eligibility"
    ADD CONSTRAINT "job_course_eligibility_course_id_fkey" FOREIGN KEY ("course_id") REFERENCES "public"."courses"("id");



ALTER TABLE ONLY "public"."job_course_eligibility"
    ADD CONSTRAINT "job_course_eligibility_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."jobs"("id");



ALTER TABLE ONLY "public"."job_locations"
    ADD CONSTRAINT "job_locations_job_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."jobs"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."job_locations"
    ADD CONSTRAINT "job_locations_location_fkey" FOREIGN KEY ("location_id") REFERENCES "public"."locations"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."job_skills"
    ADD CONSTRAINT "job_skills_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."jobs"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."job_skills"
    ADD CONSTRAINT "job_skills_skill_id_fkey" FOREIGN KEY ("skill_id") REFERENCES "public"."skill_tags"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."jobs"
    ADD CONSTRAINT "jobs_domain_id_fkey" FOREIGN KEY ("domain_id") REFERENCES "public"."job_domains"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."jobs"
    ADD CONSTRAINT "jobs_employer_id_fkey" FOREIGN KEY ("employer_id") REFERENCES "public"."employer_profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."jobs"
    ADD CONSTRAINT "jobs_role_id_fkey" FOREIGN KEY ("role_id") REFERENCES "public"."job_roles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."messages"
    ADD CONSTRAINT "messages_sender_id_fkey" FOREIGN KEY ("sender_user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."messages"
    ADD CONSTRAINT "messages_sender_student_id_fkey" FOREIGN KEY ("sender_student_id") REFERENCES "public"."students"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."messages"
    ADD CONSTRAINT "messages_sender_user_id_fkey" FOREIGN KEY ("sender_user_id") REFERENCES "public"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."messages"
    ADD CONSTRAINT "messages_ticket_id_fkey" FOREIGN KEY ("ticket_id") REFERENCES "public"."tickets"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."payments"
    ADD CONSTRAINT "payments_admission_id_fkey" FOREIGN KEY ("admission_id") REFERENCES "public"."admissions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."payments"
    ADD CONSTRAINT "payments_location_id_fkey" FOREIGN KEY ("location_id") REFERENCES "public"."locations"("id");



ALTER TABLE ONLY "public"."skills"
    ADD CONSTRAINT "skills_location_id_fkey" FOREIGN KEY ("location_id") REFERENCES "public"."locations"("id");



ALTER TABLE ONLY "public"."student_attendance"
    ADD CONSTRAINT "student_attendance_batch_id_fkey" FOREIGN KEY ("batch_id") REFERENCES "public"."batches"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."student_attendance"
    ADD CONSTRAINT "student_attendance_student_id_fkey" FOREIGN KEY ("student_id") REFERENCES "public"."students"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."students"
    ADD CONSTRAINT "students_location_id_fkey" FOREIGN KEY ("location_id") REFERENCES "public"."locations"("id");



ALTER TABLE ONLY "public"."survey_responses"
    ADD CONSTRAINT "survey_responses_student_id_fkey" FOREIGN KEY ("student_id") REFERENCES "public"."students"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."survey_responses"
    ADD CONSTRAINT "survey_responses_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."ticket_chats"
    ADD CONSTRAINT "ticket_chats_sender_student_id_fkey" FOREIGN KEY ("sender_student_id") REFERENCES "public"."students"("id");



ALTER TABLE ONLY "public"."ticket_chats"
    ADD CONSTRAINT "ticket_chats_sender_user_id_fkey" FOREIGN KEY ("sender_user_id") REFERENCES "public"."users"("id");



ALTER TABLE ONLY "public"."ticket_chats"
    ADD CONSTRAINT "ticket_chats_ticket_id_fkey" FOREIGN KEY ("ticket_id") REFERENCES "public"."tickets"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."tickets"
    ADD CONSTRAINT "tickets_assignee_id_fkey" FOREIGN KEY ("assignee_id") REFERENCES "public"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."tickets"
    ADD CONSTRAINT "tickets_location_id_fkey" FOREIGN KEY ("location_id") REFERENCES "public"."locations"("id");



ALTER TABLE ONLY "public"."tickets"
    ADD CONSTRAINT "tickets_student_id_fkey" FOREIGN KEY ("student_id") REFERENCES "public"."students"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_faculty_id_fkey" FOREIGN KEY ("faculty_id") REFERENCES "public"."faculty"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_location_id_fkey" FOREIGN KEY ("location_id") REFERENCES "public"."locations"("id");



CREATE POLICY "Admin full access" ON "public"."admission_intakes" USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Allow admin admission update" ON "public"."admissions" FOR UPDATE USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Allow public intake update" ON "public"."admission_intakes" FOR UPDATE USING (true);



CREATE POLICY "Anon can create intake" ON "public"."admission_intakes" FOR INSERT WITH CHECK (true);



CREATE POLICY "Anon cannot update" ON "public"."admission_intakes" FOR UPDATE USING (false);



CREATE POLICY "Employers can manage their own profile" ON "public"."employer_profiles" USING (("auth"."uid"() = "id"));



ALTER TABLE "public"."activities" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."admin_branches" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."admin_notifications" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "admins_can_view_all_jobs" ON "public"."jobs" FOR SELECT USING ((("auth"."jwt"() ->> 'role'::"text") = 'admin'::"text"));



CREATE POLICY "admins_manage_applications" ON "public"."job_applications" USING ((("auth"."jwt"() ->> 'role'::"text") = 'admin'::"text"));



ALTER TABLE "public"."admission_courses" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."admission_intakes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."admission_number_counters" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."admission_remarks" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."announcements" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."batch_students" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."batches" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."employer_profiles" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."faculty" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."faculty_availability" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."faculty_skills" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."faculty_substitutions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."jobs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."locations" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."messages" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."payments" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."receipt_counters" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."skills" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."student_attendance" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."students" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "students_apply_only_to_own_location_jobs" ON "public"."job_applications" FOR INSERT WITH CHECK (((("auth"."jwt"() ->> 'role'::"text") = 'student'::"text") AND (EXISTS ( SELECT 1
   FROM ("public"."job_locations" "jl"
     JOIN "public"."jobs" "j" ON (("j"."id" = "jl"."job_id")))
  WHERE (("jl"."job_id" = "job_applications"."job_id") AND ("jl"."location_id" = (("auth"."jwt"() ->> 'location_id'::"text"))::integer) AND ("j"."job_type" = 'internal'::"text"))))));



CREATE POLICY "students_can_view_all_jobs" ON "public"."jobs" FOR SELECT USING ((("auth"."jwt"() ->> 'role'::"text") = 'student'::"text"));



ALTER TABLE "public"."tickets" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."users" ENABLE ROW LEVEL SECURITY;


GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";



GRANT ALL ON FUNCTION "public"."apply_payment_to_installments"("p_payment_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."apply_payment_to_installments"("p_payment_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."apply_payment_to_installments"("p_payment_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."check_assignee_is_admin"() TO "anon";
GRANT ALL ON FUNCTION "public"."check_assignee_is_admin"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."check_assignee_is_admin"() TO "service_role";



GRANT ALL ON FUNCTION "public"."create_admission_and_student"("p_student_name" "text", "p_student_phone_number" "text", "p_father_name" "text", "p_father_phone_number" "text", "p_permanent_address" "text", "p_current_address" "text", "p_identification_type" "text", "p_identification_number" "text", "p_date_of_admission" "date", "p_course_start_date" "date", "p_batch_preference" "text", "p_remarks" "text", "p_certificate_id" "uuid", "p_discount" numeric, "p_course_ids" "uuid"[], "p_installments" "jsonb", "p_location_id" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."create_admission_and_student"("p_student_name" "text", "p_student_phone_number" "text", "p_father_name" "text", "p_father_phone_number" "text", "p_permanent_address" "text", "p_current_address" "text", "p_identification_type" "text", "p_identification_number" "text", "p_date_of_admission" "date", "p_course_start_date" "date", "p_batch_preference" "text", "p_remarks" "text", "p_certificate_id" "uuid", "p_discount" numeric, "p_course_ids" "uuid"[], "p_installments" "jsonb", "p_location_id" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_admission_and_student"("p_student_name" "text", "p_student_phone_number" "text", "p_father_name" "text", "p_father_phone_number" "text", "p_permanent_address" "text", "p_current_address" "text", "p_identification_type" "text", "p_identification_number" "text", "p_date_of_admission" "date", "p_course_start_date" "date", "p_batch_preference" "text", "p_remarks" "text", "p_certificate_id" "uuid", "p_discount" numeric, "p_course_ids" "uuid"[], "p_installments" "jsonb", "p_location_id" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."create_admission_and_student"("p_student_name" "text", "p_student_phone_number" "text", "p_father_name" "text", "p_father_phone_number" "text", "p_permanent_address" "text", "p_current_address" "text", "p_identification_type" "text", "p_identification_number" "text", "p_date_of_admission" "date", "p_course_start_date" "date", "p_batch_preference" "text", "p_remarks" "text", "p_certificate_id" "uuid", "p_discount" numeric, "p_course_ids" "uuid"[], "p_installments" "jsonb", "p_location_id" integer, "p_source_intake_id" "uuid", "p_admitted_by" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."create_admission_and_student"("p_student_name" "text", "p_student_phone_number" "text", "p_father_name" "text", "p_father_phone_number" "text", "p_permanent_address" "text", "p_current_address" "text", "p_identification_type" "text", "p_identification_number" "text", "p_date_of_admission" "date", "p_course_start_date" "date", "p_batch_preference" "text", "p_remarks" "text", "p_certificate_id" "uuid", "p_discount" numeric, "p_course_ids" "uuid"[], "p_installments" "jsonb", "p_location_id" integer, "p_source_intake_id" "uuid", "p_admitted_by" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_admission_and_student"("p_student_name" "text", "p_student_phone_number" "text", "p_father_name" "text", "p_father_phone_number" "text", "p_permanent_address" "text", "p_current_address" "text", "p_identification_type" "text", "p_identification_number" "text", "p_date_of_admission" "date", "p_course_start_date" "date", "p_batch_preference" "text", "p_remarks" "text", "p_certificate_id" "uuid", "p_discount" numeric, "p_course_ids" "uuid"[], "p_installments" "jsonb", "p_location_id" integer, "p_source_intake_id" "uuid", "p_admitted_by" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."create_course_with_books"("p_name" "text", "p_price" numeric, "p_book_ids" "uuid"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."create_course_with_books"("p_name" "text", "p_price" numeric, "p_book_ids" "uuid"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_course_with_books"("p_name" "text", "p_price" numeric, "p_book_ids" "uuid"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_sync_student_changes_to_admissions"() TO "anon";
GRANT ALL ON FUNCTION "public"."fn_sync_student_changes_to_admissions"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_sync_student_changes_to_admissions"() TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_sync_student_location_to_admissions"() TO "anon";
GRANT ALL ON FUNCTION "public"."fn_sync_student_location_to_admissions"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_sync_student_location_to_admissions"() TO "service_role";



GRANT ALL ON FUNCTION "public"."generate_admission_number"() TO "anon";
GRANT ALL ON FUNCTION "public"."generate_admission_number"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."generate_admission_number"() TO "service_role";



GRANT ALL ON FUNCTION "public"."generate_admission_number"("p_location_id" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."generate_admission_number"("p_location_id" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."generate_admission_number"("p_location_id" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."generate_receipt_number"() TO "anon";
GRANT ALL ON FUNCTION "public"."generate_receipt_number"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."generate_receipt_number"() TO "service_role";



GRANT ALL ON FUNCTION "public"."generate_rvm_receipt_number"() TO "anon";
GRANT ALL ON FUNCTION "public"."generate_rvm_receipt_number"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."generate_rvm_receipt_number"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_admission_dashboard"("search_term" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_admission_dashboard"("search_term" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_admission_dashboard"("search_term" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_admission_dashboard_v2"("search_term" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_admission_dashboard_v2"("search_term" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_admission_dashboard_v2"("search_term" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_faculty_unique_student_count"("faculty_uuid" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_faculty_unique_student_count"("faculty_uuid" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_faculty_unique_student_count"("faculty_uuid" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_unique_ticket_categories"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_unique_ticket_categories"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_unique_ticket_categories"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_unique_ticket_categories"("p_location_id" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."get_unique_ticket_categories"("p_location_id" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_unique_ticket_categories"("p_location_id" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."mark_intake_converted"() TO "anon";
GRANT ALL ON FUNCTION "public"."mark_intake_converted"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."mark_intake_converted"() TO "service_role";



GRANT ALL ON FUNCTION "public"."merge_batches_transaction"("source_batch_id" "uuid", "target_batch_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."merge_batches_transaction"("source_batch_id" "uuid", "target_batch_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."merge_batches_transaction"("source_batch_id" "uuid", "target_batch_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."record_payment"("p_admission_id" "uuid", "p_amount_paid" numeric, "p_payment_date" "date", "p_payment_method" "text", "p_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."record_payment"("p_admission_id" "uuid", "p_amount_paid" numeric, "p_payment_date" "date", "p_payment_method" "text", "p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."record_payment"("p_admission_id" "uuid", "p_amount_paid" numeric, "p_payment_date" "date", "p_payment_method" "text", "p_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."repair_all_student_ledgers"() TO "anon";
GRANT ALL ON FUNCTION "public"."repair_all_student_ledgers"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."repair_all_student_ledgers"() TO "service_role";



GRANT ALL ON FUNCTION "public"."reset_status_on_reapply"() TO "anon";
GRANT ALL ON FUNCTION "public"."reset_status_on_reapply"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."reset_status_on_reapply"() TO "service_role";



GRANT ALL ON TABLE "public"."ticket_chats" TO "anon";
GRANT ALL ON TABLE "public"."ticket_chats" TO "authenticated";
GRANT ALL ON TABLE "public"."ticket_chats" TO "service_role";



GRANT ALL ON FUNCTION "public"."send_admin_reply_and_update_status"("p_ticket_id" "uuid", "p_sender_user_id" "uuid", "p_message" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."send_admin_reply_and_update_status"("p_ticket_id" "uuid", "p_sender_user_id" "uuid", "p_message" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."send_admin_reply_and_update_status"("p_ticket_id" "uuid", "p_sender_user_id" "uuid", "p_message" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_admission_location"() TO "anon";
GRANT ALL ON FUNCTION "public"."sync_admission_location"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_admission_location"() TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_batch_schedule"() TO "anon";
GRANT ALL ON FUNCTION "public"."sync_batch_schedule"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_batch_schedule"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_admission_full"("p_admission_id" "uuid", "p_batch_preference" "text", "p_certificate_id" "uuid", "p_course_ids" "uuid"[], "p_course_start_date" "date", "p_current_address" "text", "p_date_of_admission" "date", "p_discount" numeric, "p_father_name" "text", "p_father_phone_number" "text", "p_identification_number" "text", "p_identification_type" "text", "p_installments" "jsonb", "p_location_id" "text", "p_permanent_address" "text", "p_remarks" "text", "p_student_name" "text", "p_student_phone_number" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."update_admission_full"("p_admission_id" "uuid", "p_batch_preference" "text", "p_certificate_id" "uuid", "p_course_ids" "uuid"[], "p_course_start_date" "date", "p_current_address" "text", "p_date_of_admission" "date", "p_discount" numeric, "p_father_name" "text", "p_father_phone_number" "text", "p_identification_number" "text", "p_identification_type" "text", "p_installments" "jsonb", "p_location_id" "text", "p_permanent_address" "text", "p_remarks" "text", "p_student_name" "text", "p_student_phone_number" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_admission_full"("p_admission_id" "uuid", "p_batch_preference" "text", "p_certificate_id" "uuid", "p_course_ids" "uuid"[], "p_course_start_date" "date", "p_current_address" "text", "p_date_of_admission" "date", "p_discount" numeric, "p_father_name" "text", "p_father_phone_number" "text", "p_identification_number" "text", "p_identification_type" "text", "p_installments" "jsonb", "p_location_id" "text", "p_permanent_address" "text", "p_remarks" "text", "p_student_name" "text", "p_student_phone_number" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."update_admission_full"("p_admission_id" "uuid", "p_student_name" "text", "p_student_phone_number" "text", "p_father_name" "text", "p_father_phone_number" "text", "p_permanent_address" "text", "p_current_address" "text", "p_identification_type" "text", "p_identification_number" "text", "p_date_of_admission" "date", "p_course_start_date" "date", "p_batch_preference" "text", "p_remarks" "text", "p_certificate_id" "uuid", "p_discount" numeric, "p_course_ids" "uuid"[], "p_installments" "jsonb", "p_location_id" "text", "p_updated_by" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."update_admission_full"("p_admission_id" "uuid", "p_student_name" "text", "p_student_phone_number" "text", "p_father_name" "text", "p_father_phone_number" "text", "p_permanent_address" "text", "p_current_address" "text", "p_identification_type" "text", "p_identification_number" "text", "p_date_of_admission" "date", "p_course_start_date" "date", "p_batch_preference" "text", "p_remarks" "text", "p_certificate_id" "uuid", "p_discount" numeric, "p_course_ids" "uuid"[], "p_installments" "jsonb", "p_location_id" "text", "p_updated_by" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_admission_full"("p_admission_id" "uuid", "p_student_name" "text", "p_student_phone_number" "text", "p_father_name" "text", "p_father_phone_number" "text", "p_permanent_address" "text", "p_current_address" "text", "p_identification_type" "text", "p_identification_number" "text", "p_date_of_admission" "date", "p_course_start_date" "date", "p_batch_preference" "text", "p_remarks" "text", "p_certificate_id" "uuid", "p_discount" numeric, "p_course_ids" "uuid"[], "p_installments" "jsonb", "p_location_id" "text", "p_updated_by" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."update_course_with_books"("p_course_id" "uuid", "p_name" "text", "p_price" numeric, "p_book_ids" "uuid"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."update_course_with_books"("p_course_id" "uuid", "p_name" "text", "p_price" numeric, "p_book_ids" "uuid"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_course_with_books"("p_course_id" "uuid", "p_name" "text", "p_price" numeric, "p_book_ids" "uuid"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."update_faculty_availability"("p_faculty_id" "uuid", "p_availability" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."update_faculty_availability"("p_faculty_id" "uuid", "p_availability" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_faculty_availability"("p_faculty_id" "uuid", "p_availability" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."update_modified_column"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_modified_column"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_modified_column"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_ticket_tracking_logic"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_ticket_tracking_logic"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_ticket_tracking_logic"() TO "service_role";



GRANT ALL ON FUNCTION "public"."validate_job_application_branch"() TO "anon";
GRANT ALL ON FUNCTION "public"."validate_job_application_branch"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."validate_job_application_branch"() TO "service_role";



GRANT ALL ON TABLE "public"."activities" TO "anon";
GRANT ALL ON TABLE "public"."activities" TO "authenticated";
GRANT ALL ON TABLE "public"."activities" TO "service_role";



GRANT ALL ON SEQUENCE "public"."activities_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."activities_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."activities_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."admin_branches" TO "anon";
GRANT ALL ON TABLE "public"."admin_branches" TO "authenticated";
GRANT ALL ON TABLE "public"."admin_branches" TO "service_role";



GRANT ALL ON TABLE "public"."admin_notifications" TO "anon";
GRANT ALL ON TABLE "public"."admin_notifications" TO "authenticated";
GRANT ALL ON TABLE "public"."admin_notifications" TO "service_role";



GRANT ALL ON TABLE "public"."admission_courses" TO "anon";
GRANT ALL ON TABLE "public"."admission_courses" TO "authenticated";
GRANT ALL ON TABLE "public"."admission_courses" TO "service_role";



GRANT ALL ON TABLE "public"."admission_intakes" TO "anon";
GRANT ALL ON TABLE "public"."admission_intakes" TO "authenticated";
GRANT ALL ON TABLE "public"."admission_intakes" TO "service_role";



GRANT ALL ON TABLE "public"."admission_number_counters" TO "anon";
GRANT ALL ON TABLE "public"."admission_number_counters" TO "authenticated";
GRANT ALL ON TABLE "public"."admission_number_counters" TO "service_role";



GRANT ALL ON SEQUENCE "public"."admission_number_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."admission_number_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."admission_number_seq" TO "service_role";



GRANT ALL ON TABLE "public"."admission_remarks" TO "anon";
GRANT ALL ON TABLE "public"."admission_remarks" TO "authenticated";
GRANT ALL ON TABLE "public"."admission_remarks" TO "service_role";



GRANT ALL ON TABLE "public"."admissions" TO "anon";
GRANT ALL ON TABLE "public"."admissions" TO "authenticated";
GRANT ALL ON TABLE "public"."admissions" TO "service_role";



GRANT ALL ON TABLE "public"."announcements" TO "anon";
GRANT ALL ON TABLE "public"."announcements" TO "authenticated";
GRANT ALL ON TABLE "public"."announcements" TO "service_role";



GRANT ALL ON TABLE "public"."application_chats" TO "anon";
GRANT ALL ON TABLE "public"."application_chats" TO "authenticated";
GRANT ALL ON TABLE "public"."application_chats" TO "service_role";



GRANT ALL ON TABLE "public"."batch_students" TO "anon";
GRANT ALL ON TABLE "public"."batch_students" TO "authenticated";
GRANT ALL ON TABLE "public"."batch_students" TO "service_role";



GRANT ALL ON TABLE "public"."batches" TO "anon";
GRANT ALL ON TABLE "public"."batches" TO "authenticated";
GRANT ALL ON TABLE "public"."batches" TO "service_role";



GRANT ALL ON TABLE "public"."books" TO "anon";
GRANT ALL ON TABLE "public"."books" TO "authenticated";
GRANT ALL ON TABLE "public"."books" TO "service_role";



GRANT ALL ON TABLE "public"."candidate_languages" TO "anon";
GRANT ALL ON TABLE "public"."candidate_languages" TO "authenticated";
GRANT ALL ON TABLE "public"."candidate_languages" TO "service_role";



GRANT ALL ON TABLE "public"."candidate_skills" TO "anon";
GRANT ALL ON TABLE "public"."candidate_skills" TO "authenticated";
GRANT ALL ON TABLE "public"."candidate_skills" TO "service_role";



GRANT ALL ON TABLE "public"."certificates" TO "anon";
GRANT ALL ON TABLE "public"."certificates" TO "authenticated";
GRANT ALL ON TABLE "public"."certificates" TO "service_role";



GRANT ALL ON TABLE "public"."chat_read_status" TO "anon";
GRANT ALL ON TABLE "public"."chat_read_status" TO "authenticated";
GRANT ALL ON TABLE "public"."chat_read_status" TO "service_role";



GRANT ALL ON TABLE "public"."configuration" TO "anon";
GRANT ALL ON TABLE "public"."configuration" TO "authenticated";
GRANT ALL ON TABLE "public"."configuration" TO "service_role";



GRANT ALL ON TABLE "public"."course_books" TO "anon";
GRANT ALL ON TABLE "public"."course_books" TO "authenticated";
GRANT ALL ON TABLE "public"."course_books" TO "service_role";



GRANT ALL ON TABLE "public"."courses" TO "anon";
GRANT ALL ON TABLE "public"."courses" TO "authenticated";
GRANT ALL ON TABLE "public"."courses" TO "service_role";



GRANT ALL ON TABLE "public"."domain_skills" TO "anon";
GRANT ALL ON TABLE "public"."domain_skills" TO "authenticated";
GRANT ALL ON TABLE "public"."domain_skills" TO "service_role";



GRANT ALL ON TABLE "public"."education_levels" TO "anon";
GRANT ALL ON TABLE "public"."education_levels" TO "authenticated";
GRANT ALL ON TABLE "public"."education_levels" TO "service_role";



GRANT ALL ON SEQUENCE "public"."education_levels_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."education_levels_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."education_levels_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."employer_profiles" TO "anon";
GRANT ALL ON TABLE "public"."employer_profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."employer_profiles" TO "service_role";



GRANT ALL ON TABLE "public"."external_applications" TO "anon";
GRANT ALL ON TABLE "public"."external_applications" TO "authenticated";
GRANT ALL ON TABLE "public"."external_applications" TO "service_role";



GRANT ALL ON TABLE "public"."external_candidates" TO "anon";
GRANT ALL ON TABLE "public"."external_candidates" TO "authenticated";
GRANT ALL ON TABLE "public"."external_candidates" TO "service_role";



GRANT ALL ON TABLE "public"."faculty" TO "anon";
GRANT ALL ON TABLE "public"."faculty" TO "authenticated";
GRANT ALL ON TABLE "public"."faculty" TO "service_role";



GRANT ALL ON TABLE "public"."faculty_availability" TO "anon";
GRANT ALL ON TABLE "public"."faculty_availability" TO "authenticated";
GRANT ALL ON TABLE "public"."faculty_availability" TO "service_role";



GRANT ALL ON TABLE "public"."faculty_skills" TO "anon";
GRANT ALL ON TABLE "public"."faculty_skills" TO "authenticated";
GRANT ALL ON TABLE "public"."faculty_skills" TO "service_role";



GRANT ALL ON TABLE "public"."faculty_substitutions" TO "anon";
GRANT ALL ON TABLE "public"."faculty_substitutions" TO "authenticated";
GRANT ALL ON TABLE "public"."faculty_substitutions" TO "service_role";



GRANT ALL ON TABLE "public"."follow_ups" TO "anon";
GRANT ALL ON TABLE "public"."follow_ups" TO "authenticated";
GRANT ALL ON TABLE "public"."follow_ups" TO "service_role";



GRANT ALL ON TABLE "public"."students" TO "anon";
GRANT ALL ON TABLE "public"."students" TO "authenticated";
GRANT ALL ON TABLE "public"."students" TO "service_role";



GRANT ALL ON TABLE "public"."follow_up_details" TO "anon";
GRANT ALL ON TABLE "public"."follow_up_details" TO "authenticated";
GRANT ALL ON TABLE "public"."follow_up_details" TO "service_role";



GRANT ALL ON TABLE "public"."general_chats" TO "anon";
GRANT ALL ON TABLE "public"."general_chats" TO "authenticated";
GRANT ALL ON TABLE "public"."general_chats" TO "service_role";



GRANT ALL ON TABLE "public"."installments" TO "anon";
GRANT ALL ON TABLE "public"."installments" TO "authenticated";
GRANT ALL ON TABLE "public"."installments" TO "service_role";



GRANT ALL ON TABLE "public"."job_applications" TO "anon";
GRANT ALL ON TABLE "public"."job_applications" TO "authenticated";
GRANT ALL ON TABLE "public"."job_applications" TO "service_role";



GRANT ALL ON TABLE "public"."job_course_eligibility" TO "anon";
GRANT ALL ON TABLE "public"."job_course_eligibility" TO "authenticated";
GRANT ALL ON TABLE "public"."job_course_eligibility" TO "service_role";



GRANT ALL ON TABLE "public"."job_domains" TO "anon";
GRANT ALL ON TABLE "public"."job_domains" TO "authenticated";
GRANT ALL ON TABLE "public"."job_domains" TO "service_role";



GRANT ALL ON SEQUENCE "public"."job_domains_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."job_domains_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."job_domains_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."job_locations" TO "anon";
GRANT ALL ON TABLE "public"."job_locations" TO "authenticated";
GRANT ALL ON TABLE "public"."job_locations" TO "service_role";



GRANT ALL ON TABLE "public"."job_roles" TO "anon";
GRANT ALL ON TABLE "public"."job_roles" TO "authenticated";
GRANT ALL ON TABLE "public"."job_roles" TO "service_role";



GRANT ALL ON SEQUENCE "public"."job_roles_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."job_roles_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."job_roles_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."job_skills" TO "anon";
GRANT ALL ON TABLE "public"."job_skills" TO "authenticated";
GRANT ALL ON TABLE "public"."job_skills" TO "service_role";



GRANT ALL ON TABLE "public"."jobs" TO "anon";
GRANT ALL ON TABLE "public"."jobs" TO "authenticated";
GRANT ALL ON TABLE "public"."jobs" TO "service_role";



GRANT ALL ON TABLE "public"."languages" TO "anon";
GRANT ALL ON TABLE "public"."languages" TO "authenticated";
GRANT ALL ON TABLE "public"."languages" TO "service_role";



GRANT ALL ON SEQUENCE "public"."languages_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."languages_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."languages_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."locations" TO "anon";
GRANT ALL ON TABLE "public"."locations" TO "authenticated";
GRANT ALL ON TABLE "public"."locations" TO "service_role";



GRANT ALL ON SEQUENCE "public"."locations_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."locations_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."locations_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."messages" TO "anon";
GRANT ALL ON TABLE "public"."messages" TO "authenticated";
GRANT ALL ON TABLE "public"."messages" TO "service_role";



GRANT ALL ON TABLE "public"."payments" TO "anon";
GRANT ALL ON TABLE "public"."payments" TO "authenticated";
GRANT ALL ON TABLE "public"."payments" TO "service_role";



GRANT ALL ON TABLE "public"."receipt_counters" TO "anon";
GRANT ALL ON TABLE "public"."receipt_counters" TO "authenticated";
GRANT ALL ON TABLE "public"."receipt_counters" TO "service_role";



GRANT ALL ON TABLE "public"."receipt_installments" TO "anon";
GRANT ALL ON TABLE "public"."receipt_installments" TO "authenticated";
GRANT ALL ON TABLE "public"."receipt_installments" TO "service_role";



GRANT ALL ON TABLE "public"."receipts" TO "anon";
GRANT ALL ON TABLE "public"."receipts" TO "authenticated";
GRANT ALL ON TABLE "public"."receipts" TO "service_role";



GRANT ALL ON TABLE "public"."skill_tags" TO "anon";
GRANT ALL ON TABLE "public"."skill_tags" TO "authenticated";
GRANT ALL ON TABLE "public"."skill_tags" TO "service_role";



GRANT ALL ON SEQUENCE "public"."skill_tags_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."skill_tags_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."skill_tags_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."skills" TO "anon";
GRANT ALL ON TABLE "public"."skills" TO "authenticated";
GRANT ALL ON TABLE "public"."skills" TO "service_role";



GRANT ALL ON TABLE "public"."student_attendance" TO "anon";
GRANT ALL ON TABLE "public"."student_attendance" TO "authenticated";
GRANT ALL ON TABLE "public"."student_attendance" TO "service_role";



GRANT ALL ON TABLE "public"."survey_responses" TO "anon";
GRANT ALL ON TABLE "public"."survey_responses" TO "authenticated";
GRANT ALL ON TABLE "public"."survey_responses" TO "service_role";



GRANT ALL ON TABLE "public"."system_settings" TO "anon";
GRANT ALL ON TABLE "public"."system_settings" TO "authenticated";
GRANT ALL ON TABLE "public"."system_settings" TO "service_role";



GRANT ALL ON TABLE "public"."tickets" TO "anon";
GRANT ALL ON TABLE "public"."tickets" TO "authenticated";
GRANT ALL ON TABLE "public"."tickets" TO "service_role";



GRANT ALL ON TABLE "public"."users" TO "anon";
GRANT ALL ON TABLE "public"."users" TO "authenticated";
GRANT ALL ON TABLE "public"."users" TO "service_role";



GRANT ALL ON TABLE "public"."v_admission_financial_summary" TO "anon";
GRANT ALL ON TABLE "public"."v_admission_financial_summary" TO "authenticated";
GRANT ALL ON TABLE "public"."v_admission_financial_summary" TO "service_role";



GRANT ALL ON TABLE "public"."v_admission_undertaking_status" TO "anon";
GRANT ALL ON TABLE "public"."v_admission_undertaking_status" TO "authenticated";
GRANT ALL ON TABLE "public"."v_admission_undertaking_status" TO "service_role";



GRANT ALL ON TABLE "public"."v_follow_up_task_list" TO "anon";
GRANT ALL ON TABLE "public"."v_follow_up_task_list" TO "authenticated";
GRANT ALL ON TABLE "public"."v_follow_up_task_list" TO "service_role";



GRANT ALL ON TABLE "public"."v_installment_status" TO "anon";
GRANT ALL ON TABLE "public"."v_installment_status" TO "authenticated";
GRANT ALL ON TABLE "public"."v_installment_status" TO "service_role";



GRANT ALL ON TABLE "public"."v_installments_with_location" TO "anon";
GRANT ALL ON TABLE "public"."v_installments_with_location" TO "authenticated";
GRANT ALL ON TABLE "public"."v_installments_with_location" TO "service_role";



GRANT ALL ON TABLE "public"."v_payments_with_location" TO "anon";
GRANT ALL ON TABLE "public"."v_payments_with_location" TO "authenticated";
GRANT ALL ON TABLE "public"."v_payments_with_location" TO "service_role";



GRANT ALL ON TABLE "public"."v_student_placement_metrics" TO "anon";
GRANT ALL ON TABLE "public"."v_student_placement_metrics" TO "authenticated";
GRANT ALL ON TABLE "public"."v_student_placement_metrics" TO "service_role";



GRANT ALL ON TABLE "public"."v_students_with_followup" TO "anon";
GRANT ALL ON TABLE "public"."v_students_with_followup" TO "authenticated";
GRANT ALL ON TABLE "public"."v_students_with_followup" TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";







