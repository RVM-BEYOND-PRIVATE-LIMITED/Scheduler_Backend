// server/controllers/admissionController.js

const supabase = require('../db');

/**
 * @description
 * Get Admission Dashboard rows. 
 * Super Admins see all branches; standard Admins are filtered by locationId.
 */
exports.getAllAdmissions = async (req, res) => {
  const locationId = req.locationId;
  const isSuperAdmin = req.isSuperAdmin; // From updated auth middleware

  try {
    const searchTerm = req.query.search || '';

    /* ----------------------- 1. FETCH ROW DATA ----------------------- */
    let query = supabase.from('v_admission_financial_summary').select('*');

    // ✅ ROLE-BASED FILTER: Only apply location restriction if NOT super_admin
    if (!isSuperAdmin) {
      if (!locationId) return res.status(401).json({ error: 'Location context missing.' });
      query = query.eq('location_id', locationId);
    }

    if (searchTerm) {
      query = query.or(`student_name.ilike.%${searchTerm}%,student_phone_number.ilike.%${searchTerm}%,admission_number.ilike.%${searchTerm}%`);
    }

    const { data: rows, error } = await query.order('created_at', { ascending: false });

    if (error) throw error;

    const safeRows = rows || [];

    /* ----------------------- 2. CALCULATE METRICS ---------------------- */
    const now = new Date();
    const currentMonth = now.getMonth();
    const currentYear = now.getFullYear();

    let totalCollected = 0;
    let revenueCollectedThisMonth = 0;
    let totalOutstanding = 0;
    let admissionsThisMonth = 0;
    let overdueCount = 0;

    const enrichedRows = safeRows.map((r) => {
      const createdAt = new Date(r.created_at);

      totalCollected += Number(r.total_paid || 0);
      totalOutstanding += Number(r.remaining_due || 0);

      if (createdAt.getMonth() === currentMonth && createdAt.getFullYear() === currentYear) {
        admissionsThisMonth += 1;
        revenueCollectedThisMonth += Number(r.total_paid || 0);
      }

      if (r.status === 'Pending' && new Date(r.next_task_due_date) < now) {
        overdueCount += 1;
      }

      return {
        ...r,
        undertaking_status: r.approval_status === 'Approved' ? 'Completed' : 'Pending',
      };
    });

    res.status(200).json({
      metrics: {
        totalAdmissions: enrichedRows.length,
        admissionsThisMonth,
        totalCollected,
        revenueCollectedThisMonth,
        totalOutstanding,
        overdueCount,
      },
      admissions: enrichedRows,
    });

  } catch (error) {
    console.error('Error fetching dashboard data:', error);
    res.status(500).json({ error: 'An unexpected error occurred.' });
  }
};

/**
 * @description
 * Get a single admission with all related details.
 * Standard admins are restricted to their branch; Super Admins have global access.
 */
exports.getAdmissionById = async (req, res) => {
  const { id } = req.params;

  try {
    const { data: admission, error: admissionError } = await supabase
      .from('admissions')
      .select('*')
      .eq('id', id)
      .single();

    if (admissionError) throw admissionError;
    if (!admission) {
      return res.status(404).json({ error: 'Admission not found' });
    }

    // ✅ SECURITY GATE: Prevent branch-hopping unless super_admin
    if (!req.isSuperAdmin && Number(admission.location_id) !== Number(req.locationId)) {
      return res.status(403).json({ error: "Access denied. You do not have permission to view this branch's data." });
    }

    const { data: coursesData, error: coursesError } = await supabase
      .from('admission_courses')
      .select('courses(*)')
      .eq('admission_id', id);

    if (coursesError) throw coursesError;

    const courses = coursesData ? coursesData.map((item) => item.courses) : [];

    const { data: installments, error: installmentsError } = await supabase
      .from('v_installment_status')
      .select('*')
      .eq('admission_id', id)
      .order('due_date', { ascending: true });

    if (installmentsError) throw installmentsError;

    res.status(200).json({
      ...admission,
      courses,
      installments: installments || [],
    });
  } catch (error) {
    console.error(`Error fetching admission ${id}:`, error);
    if (error.code === 'PGRST116') return res.status(404).json({ error: 'Admission not found' });
    res.status(500).json({ error: 'An unexpected error occurred.' });
  }
};

/**
 * @description
 * Create a new admission.
 */
exports.createAdmission = async (req, res) => {
  const {
    student_name, student_phone_number, father_name, father_phone_number,
    permanent_address, current_address, identification_type, identification_number,
    date_of_admission, course_start_date, batch_preference, remarks,
    certificate_id, discount, course_ids, installments, source_intake_id,
  } = req.body;

  const locationId = req.locationId;
  const userId = req.user?.id;

  if (!locationId || !userId) {
    return res.status(401).json({ error: 'Authentication failed.' });
  }

  if (!student_name || !student_phone_number || !date_of_admission) {
    return res.status(400).json({ error: 'Required fields missing.' });
  }

  try {
    const { data, error } = await supabase.rpc(
      'create_admission_and_student',
      {
        p_student_name: student_name,
        p_student_phone_number: student_phone_number,
        p_father_name: father_name || null,
        p_father_phone_number: father_phone_number || null,
        p_permanent_address: permanent_address || null,
        p_current_address: current_address || null,
        p_identification_type: identification_type || null,
        p_identification_number: identification_number || null,
        p_date_of_admission: date_of_admission,
        p_course_start_date: course_start_date || null,
        p_batch_preference: batch_preference || null,
        p_remarks: remarks || null,
        p_certificate_id: (certificate_id && certificate_id !== 'null') ? certificate_id : null,
        p_discount: Number(discount) || 0,
        p_course_ids: course_ids,
        p_installments: installments, 
        p_location_id: locationId,
        p_admitted_by: userId,
        p_source_intake_id: source_intake_id || null, 
      }
    );

    if (error) throw error;

    res.status(201).json({ message: 'Admission created successfully', admission_id: data });
  } catch (error) {
    res.status(500).json({ error: error.message || 'Error creating admission.' });
  }
};

/**
 * @description
 * Update an existing admission.
 * STRICT SECURITY: Only roles with 'super_admin' can proceed.
 */
exports.updateAdmission = async (req, res) => {
  const { id } = req.params;
  
  // ✅ ROLE-BASED SECURITY GATE
  if (!req.isSuperAdmin) {
    return res.status(403).json({ error: "Access denied. Super Admin privileges required to update admissions." });
  }

  const {
    student_name, student_phone_number, father_name, father_phone_number,
    permanent_address, current_address, identification_type, identification_number,
    date_of_admission, course_start_date, batch_preference, remarks,
    certificate_id, discount, course_ids, installments
  } = req.body;

  const locationId = req.locationId; 
  const userId = req.user?.id;

  try {
    const finalLocationId = locationId ? String(locationId) : null;

    if (!finalLocationId) {
       return res.status(400).json({ error: "Location identification is missing." });
    }

    const { error } = await supabase.rpc('update_admission_full', {
      p_admission_id: id,
      p_student_name: student_name,
      p_student_phone_number: student_phone_number,
      p_father_name: father_name || null,
      p_father_phone_number: father_phone_number || null,
      p_permanent_address: permanent_address || null,
      p_current_address: current_address || null,
      p_identification_type: identification_type || null,
      p_identification_number: identification_number || null,
      p_date_of_admission: date_of_admission,
      p_course_start_date: course_start_date || null,
      p_batch_preference: batch_preference || null,
      p_remarks: remarks || null,
      p_certificate_id: (certificate_id && certificate_id !== 'null' && certificate_id.length > 20) ? certificate_id : null,
      p_discount: Number(discount) || 0,
      p_course_ids: Array.isArray(course_ids) ? course_ids : [],
      p_installments: Array.isArray(installments) ? installments : [], 
      p_location_id: finalLocationId, 
      p_updated_by: userId
    });

    if (error) throw error;
    res.status(200).json({ message: 'Admission updated successfully' });

  } catch (error) {
    console.error('Update Error:', error);
    res.status(500).json({ error: error.message });
  }
};

/**
 * @description
 * Mark a student as a Dropout.
 * STRICT SECURITY: Only roles with 'super_admin' can proceed.
 */
exports.markStudentDropout = async (req, res) => {
  const { id } = req.params;
  const { dropout_reason } = req.body;
  const userId = req.user?.id;

  if (!id || id === 'undefined' || id.length < 30) {
    return res.status(400).json({ error: "Invalid Admission ID." });
  }

  // ✅ ROLE-BASED SECURITY GATE
  if (!req.isSuperAdmin) {
    return res.status(403).json({ error: "Access denied. Super Admin privileges required to process dropouts." });
  }

  try {
    const { error: updateError } = await supabase
      .from('admissions')
      .update({ 
        joined: false, 
        remarks: `DROPOUT: ${dropout_reason}` 
      })
      .eq('id', id);

    if (updateError) throw updateError;

    await supabase.from('admission_remarks').insert([{
      admission_id: id,
      remark_text: `MARKED AS DROPOUT. Reason: ${dropout_reason}`,
      created_by: userId
    }]);

    res.status(200).json({ message: 'Dropout processed.' });
  } catch (error) {
    console.error('Dropout Error:', error);
    res.status(500).json({ error: error.message });
  }
};

exports.checkAdmissionByPhone = async (req, res) => {
  try {
    const { phone } = req.params;
    const { data, error } = await supabase
      .from('admissions')
      .select('id, undertaking_completed')
      .eq('student_phone_number', phone)
      .maybeSingle();

    if (error) return res.status(500).json({ error: 'Lookup failed' });
    if (!data) return res.json({ mode: 'INTAKE' });

    return res.json({
      mode: 'ADMISSION',
      admission_id: data.id,
      undertaking_completed: data.undertaking_completed,
    });
  } catch (err) {
    res.status(500).json({ error: 'Internal server error' });
  }
};

// server/controllers/admissionController.js

/**
 * @description
 * Toggle the undertaking status between Completed and Pending.
 */
exports.toggleUndertakingStatus = async (req, res) => {
  const { id } = req.params;
  const { completed } = req.body; // Expecting boolean true/false
  const userId = req.user?.id;

  try {
    const statusText = completed ? 'Completed' : 'Pending';
    
    const { data, error } = await supabase
      .from('admissions')
      .update({ 
        undertaking_completed: completed,
        undertaking_status: statusText,
        undertaking_completed_at: completed ? new Date() : null,
        updated_at: new Date()
      })
      .eq('id', id)
      .select()
      .single();

    if (error) throw error;

    // Log the change in remarks
    await supabase.from('admission_remarks').insert([{
      admission_id: id,
      remark_text: `Undertaking status manually changed to: ${statusText}`,
      created_by: userId
    }]);

    res.status(200).json({ message: `Undertaking marked as ${statusText}`, data });
  } catch (error) {
    console.error('Toggle Undertaking Error:', error);
    res.status(500).json({ error: error.message });
  }
};