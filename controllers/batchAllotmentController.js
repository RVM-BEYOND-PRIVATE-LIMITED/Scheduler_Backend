// server/controllers/batchAllotmentController.js
const supabase = require('../db');

/* ===========================================================
   GET BATCH ALLOTMENT LIST (LOCATION & ROLE AWARE)
   =========================================================== */
exports.getBatchAllotmentList = async (req, res) => {
  const userLocationId = req.locationId ? Number(req.locationId) : null;
  const isSuperAdmin = req.isSuperAdmin;

  try {
    // ✅ Extracting startDate and endDate for range filtering
    const { 
      search = '', 
      location_id, 
      filter = 'all_pending',
      startDate,
      endDate 
    } = req.query;

    let query = supabase
      .from('v_admission_financial_summary')
      .select(`
        admission_id,
        admission_number,
        student_name,
        student_phone_number,
        courses_str,
        date_of_admission,
        location_id,
        batch_names,
        remarks,
        course_start_date,
        joined
      `);

    /* --- 🛡️ LOCATION FILTERING --- */
    if (isSuperAdmin) {
      if (location_id && !['all', 'All'].includes(location_id)) {
        query = query.eq('location_id', Number(location_id));
      }
    } else {
      if (!userLocationId) return res.status(401).json({ error: 'Location context missing.' });
      query = query.eq('location_id', userLocationId);
    }

    /* --- 📅 NEW: DATE RANGE FILTERING --- */
    if (startDate) {
      query = query.gte('date_of_admission', startDate);
    }
    if (endDate) {
      query = query.lte('date_of_admission', endDate);
    }

    /* --- 🔍 IMPROVED FILTER LOGIC --- */
    if (filter === 'allotted_not_joined') {
      query = query
        .not('batch_names', 'is', null)
        .filter('batch_names', 'cs', '{}') 
        .neq('batch_names', '{}')          
        .eq('joined', false);
    } 
    else if (filter === 'joined') {
      query = query.eq('joined', true);
    } 
    else if (filter === 'all_pending') {
      query = query.eq('joined', false);
    }

    /* --- 🔎 SEARCH & SORT --- */
    if (search) {
      query = query.or(`student_name.ilike.%${search}%,admission_number.ilike.%${search}%,student_phone_number.ilike.%${search}%`);
    }

    const { data: admissions, error } = await query.order('date_of_admission', { ascending: false });

    if (error) throw error;
    if (!admissions) return res.json([]);

    /* --- 🏗️ RESPONSE MAPPING --- */
    const result = admissions.map(row => ({
        admission_id: row.admission_id,
        admission_number: row.admission_number,
        student_name: row.student_name,
        student_phone_number: row.student_phone_number,
        course_name: row.courses_str || 'No Course Selected',
        admission_date: row.date_of_admission,
        batch_names: Array.isArray(row.batch_names) ? row.batch_names : [],
        joined: row.joined ?? false,
        joining_date: row.course_start_date ?? null,
        remarks: row.remarks ?? '',
        location_id: row.location_id
    }));

    res.json(result);

  } catch (err) {
    console.error('Batch Allotment Fetch Error:', err);
    res.status(500).json({ error: 'Failed to load batch allotment list' });
  }
};

/* ===========================================================
   UPDATE BATCH ALLOTMENT (CONTROLLER FIX)
   =========================================================== */
exports.updateBatchAllotment = async (req, res) => {
  const { admissionId } = req.params;
  const { joined, joining_date, remarks } = req.body;
  const isSuperAdmin = req.isSuperAdmin;
  const locationId = req.locationId;
  
  const staffIdentifier = req.user?.username || 'System'; 

  try {
    // ✅ STEP 1: Fetch details and check current batch allotment status
    const { data: targetAdmission, error: checkErr } = await supabase
      .from('v_admission_financial_summary') // Using view to see batch_names easily
      .select('location_id, batch_names')
      .eq('admission_id', admissionId)
      .single();

    if (checkErr || !targetAdmission) return res.status(404).json({ error: "Admission not found." });

    /* --- 🛡️ SECURITY CHECK --- */
    if (!isSuperAdmin && Number(targetAdmission.location_id) !== Number(locationId)) {
      return res.status(403).json({ error: "Unauthorized: You can only update students in your own branch." });
    }

    /* --- 🚫 BATCH VALIDATION: Cannot mark Joined if no batches allotted --- */
    const hasBatches = Array.isArray(targetAdmission.batch_names) && targetAdmission.batch_names.length > 0;
    
    if (joined === true && !hasBatches) {
      return res.status(400).json({ 
        error: "Validation Failed: Student cannot be marked as 'Joined' until at least one batch has been allotted." 
      });
    }

    // 2. Update main admission
    const { error: admissionErr } = await supabase
      .from('admissions')
      .update({
        joined,
        course_start_date: joining_date,
        remarks,
      })
      .eq('id', admissionId);

    if (admissionErr) throw admissionErr;

    // 3. Log History
    if (remarks && remarks.trim() !== "") {
      await supabase
        .from('admission_remarks')
        .insert({
            admission_id: admissionId,
            remark_text: remarks,
            created_by: staffIdentifier 
        });
    }

    res.json({ success: true });
  } catch (err) {
    console.error('Batch Allotment Update Error:', err);
    res.status(500).json({ error: 'Failed to update batch allotment' });
  }
};

exports.getRemarkHistory = async (req, res) => {
  const { admissionId } = req.params;
  try {
    const { data, error } = await supabase
      .from('admission_remarks')
      .select('remark_text, created_at, created_by')
      .eq('admission_id', admissionId)
      .order('created_at', { ascending: false });

    if (error) throw error;
    res.json(data);
  } catch (err) {
    console.error('Fetch History Error:', err);
    res.status(500).json({ error: 'Failed to fetch history' });
  }
};