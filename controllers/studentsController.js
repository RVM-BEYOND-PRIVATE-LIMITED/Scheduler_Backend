const supabase = require('../db');
const { logActivity } = require('./logActivity');

/**
 * Fetches students with optional global view for Super Admins.
 */
const getAllStudents = async (req, res) => {
  const isSuperAdmin = req.isSuperAdmin;
  const userLocationId = req.locationId;
  const { search, location_id } = req.query; // ✅ location_id added for Super Admin

  if (!userLocationId && !isSuperAdmin) {
    return res.status(401).json({ error: 'Authentication required.' });
  }

  try {
    let query = supabase
      .from('students')
      .select(`
        *,
        follow_up:v_follow_up_task_list (
          next_task_due_date,
          total_due,
          task_count
        )
      `);

    /* -------------------- 🛡️ ROLE-BASED LOCATION LOGIC -------------------- */
    if (isSuperAdmin) {
      // Super Admin: View a specific branch or global dataset
      if (location_id && location_id !== 'all') {
        query = query.eq('location_id', Number(location_id));
      }
    } else {
      // Standard Admin: Strictly restricted to their own branch
      query = query.eq('location_id', userLocationId);
    }

    if (search) {
      const safeSearch = search.replace(/%/g, ''); 
      query = query.or(`name.ilike.%${safeSearch}%,admission_number.ilike.%${safeSearch}%,phone_number.ilike.%${safeSearch}%`);
    }

    const { data: students, error } = await query.order('name', { ascending: true });
    if (error) throw error;

    const processedStudents = (students || []).map(student => {
      const followData = Array.isArray(student.follow_up) 
        ? student.follow_up[0] 
        : student.follow_up;
      
      const balance = followData ? Number(followData.total_due || 0) : 0;
      const nextDate = followData?.next_task_due_date;
      const hasTasks = Number(followData?.task_count || 0) > 0;
      
      let dynamicRemark = '';

      if (followData && hasTasks) {
        if (balance <= 0) {
          dynamicRemark = 'FULL PAID';
        } else if (nextDate) {
          const d = new Date(nextDate);
          dynamicRemark = !isNaN(d.getTime()) 
            ? `${String(d.getDate()).padStart(2, '0')} ${d.toLocaleString('en-GB', { month: 'short' })} ${d.getFullYear()}`
            : 'Date Pending';
        } else {
          dynamicRemark = student.remarks || 'Follow-up Active';
        }
      } else {
        dynamicRemark = student.remarks || 'No Remark';
      }

      return { 
        ...student, 
        remarks: dynamicRemark,
        total_due_amount: balance,
        follow_up: followData
      };
    });

    res.status(200).json({ 
      students: processedStudents, 
      count: processedStudents.length 
    });

  } catch (error) {
    console.error('Error in getAllStudents:', error);
    res.status(500).json({ error: error.message });
  }
};

/**
 * Creates a new student record (Strictly Branch-Specific).
 */
const createStudent = async (req, res) => {
  // Creating students is always tied to the active branch session
  const locationId = req.locationId;
  if (!locationId) {
    return res.status(401).json({ error: 'Authentication required with location.' });
  }

  const { name, admission_number, phone_number, remarks } = req.body;

  if (!name || !admission_number) {
    return res.status(400).json({ error: 'Name and Admission Number are required.' });
  }

  try {
    const { data, error } = await supabase
      .from('students')
      .insert([{ 
        name, 
        admission_number, 
        phone_number, 
        remarks,
        location_id: locationId 
      }])
      .select()
      .single(); 

    if (error) throw error;

    await logActivity('created', `student ${data.name}`, req.user?.id || 'Admin');
    res.status(201).json(data);
  } catch (error) {
    if (error.code === '23505' && error.message.includes('students_admission_number_location_key')) { 
      return res.status(409).json({ error: `Admission number '${admission_number}' already exists at this location.` });
    }
    res.status(500).json({ error: error.message });
  }
};

/**
 * Updates an existing student record (Location Safe).
 */
const updateStudent = async (req, res) => {
  const { id } = req.params;
  const { name, admission_number, phone_number, remarks } = req.body;
  const isSuperAdmin = req.isSuperAdmin;
  const userLocationId = req.locationId;

  try {
    // Branch Security: Ensure the editor belongs to the student's branch
    const { data: currentStudent } = await supabase.from('students').select('location_id').eq('id', id).single();
    if (!isSuperAdmin && Number(currentStudent?.location_id) !== Number(userLocationId)) {
        return res.status(403).json({ error: "Access denied: Unauthorized branch access." });
    }

    const { data, error } = await supabase
      .from('students')
      .update({ name, admission_number, phone_number, remarks })
      .eq('id', id)
      .select()
      .single(); 

    if (error) throw error;
    if (!data) return res.status(404).json({ error: 'Student not found.' });

    await logActivity('updated', `student ${data.name}`, req.user?.id || 'Admin');
    res.status(200).json(data);
  } catch (error) {
    if (error.code === '23505' && error.message.includes('students_admission_number_location_key')) {
      return res.status(409).json({ error: `Admission number exists at this location.` });
    }
    res.status(500).json({ error: error.message });
  }
};

/**
 * Deletes a student record (Location Safe).
 */
const deleteStudent = async (req, res) => {
  const { id } = req.params;
  const isSuperAdmin = req.isSuperAdmin;
  const userLocationId = req.locationId;

  try {
    const { data: currentStudent } = await supabase.from('students').select('location_id').eq('id', id).single();
    if (!isSuperAdmin && Number(currentStudent?.location_id) !== Number(userLocationId)) {
        return res.status(403).json({ error: "Access denied: Unauthorized branch access." });
    }

    const { error } = await supabase.from('students').delete().eq('id', id);
    if (error) throw error;

    await logActivity('deleted', `student with id ${id}`, req.user?.id || 'Admin');
    res.status(204).send();
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
};

/**
 * Fetches all batches a specific student is enrolled in.
 */
const getStudentBatches = async (req, res) => {
  const { id } = req.params;
  try {
    const { data, error } = await supabase
      .from('batch_students')
      .select('batches(*, faculty:faculty_id(*))') 
      .eq('student_id', id);

    if (error) throw error;
    
    const batches = (data || []).map(item => item.batches).filter(Boolean);
    res.json({ batches }); 
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
};

/**
 * Updates a student's defaulter status.
 * RIGID RULE: Admission Number is COMPULSORY to mark as defaulter.
 */
const setDefaulterStatus = async (req, res) => {
  // ✅ 1. Trim the ID to remove hidden spaces/newlines
  const id = req.params.id ? req.params.id.trim() : null;
  const is_marking_defaulter = req.body.is_defaulter === false ? false : true;
  const { reason } = req.body;
  const userLocationId = req.locationId; // From your auth middleware
  const isSuperAdmin = req.isSuperAdmin;

  if (!id) return res.status(400).json({ error: "Student ID is required." });

  try {
    // 2. Fetch the student first - using .maybeSingle() to avoid 404 crashes
    const { data: student, error: fetchError } = await supabase
      .from('students')
      .select('id, name, admission_number, location_id')
      .eq('id', id)
      .maybeSingle();

    if (fetchError) throw fetchError;

    // 🕵️ DEBUG LOG: See exactly what the server found
    if (!student) {
      console.log(`404 DEBUG: No student found in DB for ID: [${id}]`);
      return res.status(404).json({ error: "Student record not found in database." });
    }

    // ✅ 3. Permission Check: Ensure Admin is in the right branch
    if (!isSuperAdmin && student.location_id !== userLocationId) {
       return res.status(403).json({ 
         error: "Permission Denied", 
         details: `Student belongs to location ${student.location_id}, but you are logged into ${userLocationId}` 
       });
    }

    // ✅ 4. Compulsory Admission Number Check
    const admNo = (student.admission_number || "").trim();
    if (is_marking_defaulter && (!admNo || admNo === "" || admNo === "N/A")) {
      return res.status(400).json({ 
        error: "Action Blocked: Student must have a valid Admission Number to be marked as a defaulter." 
      });
    }

    // 5. Perform the Update
    const updateData = { 
        is_defaulter: is_marking_defaulter,
        defaulter_reason: is_marking_defaulter ? (reason || "No reason provided") : null,
        defaulter_marked_at: is_marking_defaulter ? new Date().toISOString() : null,
        updated_at: new Date()
    };

    const { data: updated, error: updateError } = await supabase
      .from('students')
      .update(updateData)
      .eq('id', id)
      .select()
      .single();

    if (updateError) throw updateError;

    res.json({
      message: is_marking_defaulter ? "Marked as defaulter" : "Status cleared",
      student_name: updated.name
    });

  } catch (err) {
    console.error("Defaulter Error:", err.message);
    res.status(500).json({ error: err.message });
  }
};

module.exports = {
  getAllStudents,
  createStudent,
  updateStudent,
  deleteStudent,
  getStudentBatches,
  setDefaulterStatus
};