const supabase = require('../db');
const { logActivity } = require('./logActivity');

// This helper is perfect, no changes.
const getDynamicStatus = (startDate, endDate) => {
  const now = new Date();
  const start = new Date(startDate);
  const end = new Date(endDate);
  now.setHours(0, 0, 0, 0);
  start.setHours(0, 0, 0, 0);
  end.setHours(0, 0, 0, 0);
  if (now < start) return 'upcoming';
  if (now >= start && now <= end) return 'active';
  return 'completed';
};

const getAllBatches = async (req, res) => {
  try {
    const isSuperAdmin = req.isSuperAdmin;
    const userLocationId = req.locationId;
    const { facultyId, location_id } = req.query; // ✅ location_id added for Super Admin filtering

    if (!userLocationId && !isSuperAdmin) {
      return res.status(401).json({ error: 'Authentication required with location.' });
    }

    const today = new Date().toISOString().split('T')[0];

    /* -------------------- 🛡️ ROLE-BASED LOCATION LOGIC -------------------- */
    let targetLocationId = null;
    if (isSuperAdmin) {
      // Super Admin: Can focus on one branch or see all if 'all'/undefined
      if (location_id && location_id !== 'all' && location_id !== 'All') {
        targetLocationId = Number(location_id);
      }
    } else {
      // Admin/Faculty: Strictly restricted to their own branch
      targetLocationId = Number(userLocationId);
    }

    const [batchesResult, substitutionsResult, allFacultiesResult] = await Promise.all([
      (() => {
        let query = supabase.from('batches').select(`
          *,
          faculty:faculty_id(*),
          skill:skill_id(*),
          students:batch_students(count)
        `);
        
        // Apply location filter if we are NOT in global Super Admin mode
        if (targetLocationId) {
          query = query.eq('location_id', targetLocationId);
        }
        
        if (facultyId) {
          query = query.eq('faculty_id', facultyId);
        }
        return query;
      })(),

      (() => {
        let subQuery = supabase.from('faculty_substitutions')
          .select(`*, substitute:substitute_faculty_id(*), batches!inner(location_id)`)
          .lte('start_date', today)
          .gte('end_date', today);
        
        if (targetLocationId) {
          subQuery = subQuery.eq('batches.location_id', targetLocationId);
        }
        return subQuery;
      })(),

      (() => {
        let facQuery = supabase.from('faculty').select('*');
        if (targetLocationId) {
          facQuery = facQuery.eq('location_id', targetLocationId);
        }
        return facQuery;
      })()
    ]);

    if (batchesResult.error) throw batchesResult.error;
    
    const formattedData = (batchesResult.data || []).map(batch => {
      const activeSub = (substitutionsResult.data || []).find(sub => sub.batch_id === batch.id);
      const currentStatus = getDynamicStatus(batch.start_date, batch.end_date);

      let finalBatch = {
        ...batch,
        status: currentStatus, 
        students: batch.students[0]?.count || 0,
        isSubstituted: false,
      };

      if (activeSub && activeSub.substitute) {
        const originalFaculty = (allFacultiesResult.data || []).find(f => f.id === activeSub.original_faculty_id);
        finalBatch.isSubstituted = true;
        finalBatch.faculty = activeSub.substitute;
        finalBatch.faculty_id = activeSub.substitute_faculty_id;
        finalBatch.original_faculty = originalFaculty ? { id: originalFaculty.id, name: originalFaculty.name } : null;
        finalBatch.substitutionDetails = activeSub;
      }
      return finalBatch;
    });
    
    // Logic for Faculty Users: Filter the scoped results to only show their own batches
    if (req.user && req.user.role === 'faculty') {
        const targetFacultyId = req.user.faculty_id;
        return res.json(formattedData.filter(batch => batch.faculty_id === targetFacultyId));
    }

    res.json(formattedData);
  } catch (error) {
    console.error("Error in getAllBatches:", error);
    res.status(500).json({ error: error.message });
  }
};


const createBatch = async (req, res) => {
  // --- NEW --- This route MUST be protected by auth to get req.locationId
  if (!req.locationId) {
    return res.status(401).json({ error: 'Authentication required with location.' });
  }

  const {
    name, description, startDate, endDate, startTime, endTime,
    facultyId, skillId, maxStudents, studentIds, daysOfWeek, status
  } = req.body;

  if (!name) {
    return res.status(400).json({ error: 'Batch name is required' });
  }

  try {
    // --- Faculty availability check logic ---
    // NO CHANGE NEEDED. This is based on a unique UUID (facultyId)
    const { data: facultyAvailability, error: availabilityError } = await supabase
      .from('faculty_availability')
      .select('day_of_week, start_time, end_time')
      .eq('faculty_id', facultyId);
    // ... (rest of availability check is fine) ...
    if (availabilityError) throw availabilityError;

    const newStartTime = new Date(`1970-01-01T${startTime}Z`);
    const newEndTime = new Date(`1970-01-01T${endTime}Z`);
    const newStartDate = new Date(startDate);
    const newEndDate = new Date(endDate);

    for (const day of daysOfWeek) {
      const availabilityForDay = facultyAvailability.find(a => a.day_of_week.toLowerCase() === day.toLowerCase());
      if (!availabilityForDay) {
        return res.status(400).json({ error: `Faculty is not available on ${day}.` });
      }
      const facultyStartTime = new Date(`1970-01-01T${availabilityForDay.start_time}Z`);
      const facultyEndTime = new Date(`1970-01-01T${availabilityForDay.end_time}Z`);
      if (newStartTime < facultyStartTime || newEndTime > facultyEndTime) {
        return res.status(400).json({ error: `Batch time on ${day} is outside of faculty's available hours.` });
      }
    }

    // --- Scheduling conflict check logic ---
    const today = new Date().toISOString().split('T')[0];
    const { data: existingBatches, error: existingBatchesError } = await supabase
      .from('batches')
      .select('name, start_time, end_time, days_of_week, start_date, end_date')
      .eq('faculty_id', facultyId)
      .gte('end_date', today)
      // --- MODIFIED --- Only check for conflicts at the *same location*
      .eq('location_id', req.locationId); 

    if (existingBatchesError) throw existingBatchesError;

    // ... (rest of conflict check logic is fine) ...
    for (const batch of existingBatches) {
      const existingStartTime = new Date(`1970-01-01T${batch.start_time}Z`);
      const existingEndTime = new Date(`1970-01-01T${batch.end_time}Z`);
      const existingStartDate = new Date(batch.start_date);
      const existingEndDate = new Date(batch.end_date);
      const daysOverlap = daysOfWeek.some(day => batch.days_of_week.map(d => d.toLowerCase()).includes(day.toLowerCase()));
      const datesOverlap = newStartDate <= existingEndDate && newEndDate >= existingStartDate;

      if (daysOverlap && datesOverlap && newStartTime < existingEndTime && newEndTime > existingStartTime) {
        return res.status(409).json({ error: `Faculty has a scheduling conflict with batch: ${batch.name}.` });
      }
    }
    
    // --- CORE INSERT LOGIC ---
    const { data: batchData, error: batchError } = await supabase
      .from('batches')
      .insert([{
        name, description,
        start_date: startDate, end_date: endDate,
        start_time: startTime, end_time: endTime,
        faculty_id: facultyId, skill_id: skillId,
        max_students: maxStudents, days_of_week: daysOfWeek,
        status,
        location_id: req.locationId, // --- MODIFIED --- Add the location ID
      }])
      .select('id, name')
      .single();

    if (batchError) throw batchError;

    // ... (rest of function is fine, based on UUIDs) ...
    if (studentIds && studentIds.length > 0) {
      const batchStudentData = studentIds.map((studentId) => ({ batch_id: batchData.id, student_id: studentId }));
      const { error: batchStudentError } = await supabase.from('batch_students').insert(batchStudentData);
      if (batchStudentError) throw batchStudentError;
    }
    // ...
    const { data: finalBatch, error: finalBatchError } = await supabase
      .from('batches')
      .select(`*, faculty:faculty_id(*), skill:skill_id(*), students:batch_students(students(*))`)
      .eq('id', batchData.id)
      .single();

    if (finalBatchError) throw finalBatchError;

    const formattedBatch = { ...finalBatch, students: finalBatch.students.map(s => s.students).filter(Boolean) };
    await logActivity('created', `batch ${formattedBatch.name}`, 'Admin');
    res.status(201).json(formattedBatch);

  } catch (error) {
    // --- MODIFIED --- Updated error message for new schema's unique constraint
    if (error.code === '23505' && error.message.includes('batches_name_location_key')) {
      return res.status(409).json({ error: `A batch with the name '${name}' already exists at this location.` });
    }
    if (error.code === '23503') {
      if (error.message.includes('batches_faculty_id_fkey')) return res.status(400).json({ error: `Faculty with ID ${facultyId} does not exist.` });
      if (error.message.includes('batches_skill_id_fkey')) return res.status(400).json({ error: `Skill with ID ${skillId} does not exist.` });
      if (error.message.includes('batch_students_student_id_fkey')) return res.status(400).json({ error: 'One or more student IDs are invalid.' });
    }
    res.status(500).json({ error: error.message });
  }
};

const updateBatch = async (req, res) => {
  // --- NEW --- This route MUST be protected by auth to get req.locationId
  if (!req.locationId) {
    return res.status(401).json({ error: 'Authentication required with location.' });
  }

  const { id } = req.params; // The ID of the batch being updated
  const {
    name, description, startDate, endDate, startTime, endTime,
    facultyId, skillId, maxStudents, studentIds, daysOfWeek,
  } = req.body;

  try {
    // --- Faculty availability check (same as in createBatch) ---
    // NO CHANGE NEEDED. Based on unique UUID.
    const { data: facultyAvailability, error: availabilityError } = await supabase
      .from('faculty_availability')
      .select('day_of_week, start_time, end_time')
      .eq('faculty_id', facultyId);
    // ... (rest of availability check is fine) ...
    if (availabilityError) throw availabilityError;
    
    const newStartTime = new Date(`1970-01-01T${startTime}Z`);
    const newEndTime = new Date(`1970-01-01T${endTime}Z`);

    for (const day of daysOfWeek) {
      const availabilityForDay = facultyAvailability.find(a => a.day_of_week.toLowerCase() === day.toLowerCase());
      if (!availabilityForDay) {
        return res.status(400).json({ error: `Faculty is not available on ${day}.` });
      }
      const facultyStartTime = new Date(`1970-01-01T${availabilityForDay.start_time}Z`);
      const facultyEndTime = new Date(`1970-01-01T${availabilityForDay.end_time}Z`);
      if (newStartTime < facultyStartTime || newEndTime > facultyEndTime) {
        return res.status(400).json({ error: `Batch time on ${day} is outside of faculty's available hours.` });
      }
    }

    // --- Scheduling conflict check ---
    const today = new Date().toISOString().split('T')[0];
    const { data: existingBatches, error: existingBatchesError } = await supabase
      .from('batches')
      .select('id, name, start_time, end_time, days_of_week, start_date, end_date')
      .eq('faculty_id', facultyId)
      .neq('id', id)
      .gte('end_date', today)
      // --- MODIFIED --- Only check for conflicts at the *same location*
      .eq('location_id', req.locationId); 

    if (existingBatchesError) throw existingBatchesError;

    // ... (rest of conflict check logic is fine) ...
    const newStartDate = new Date(startDate);
    const newEndDate = new Date(endDate);
    for (const batch of existingBatches) {
      // ...
      const existingStartTime = new Date(`1970-01-01T${batch.start_time}Z`);
      const existingEndTime = new Date(`1970-01-01T${batch.end_time}Z`);
      const existingStartDate = new Date(batch.start_date);
      const existingEndDate = new Date(batch.end_date);
      const daysOverlap = daysOfWeek.some(day => batch.days_of_week.map(d => d.toLowerCase()).includes(day.toLowerCase()));
      const datesOverlap = newStartDate <= existingEndDate && newEndDate >= existingStartDate;

      if (daysOverlap && datesOverlap && newStartTime < existingEndTime && newEndTime > existingStartTime) {
        return res.status(409).json({ error: `Faculty has a scheduling conflict with other batch: ${batch.name}.` });
      }
    }
    
    // --- Original update logic ---
    // NO CHANGE NEEDED. We are updating by a unique 'id' (UUID).
    // We don't need to add location_id to the update.
    const status = getDynamicStatus(startDate, endDate);
    // ... (rest of update logic is fine) ...
    const { error: deleteError } = await supabase.from('batch_students').delete().eq('batch_id', id);
    if (deleteError) throw deleteError;

    if (studentIds && studentIds.length > 0) {
      const batchStudentData = studentIds.filter(Boolean).map((studentId) => ({ batch_id: id, student_id: studentId }));
      if (batchStudentData.length > 0) {
        const { error: insertError } = await supabase.from('batch_students').insert(batchStudentData);
        if (insertError) throw insertError;
      }
    }

    const { data, error } = await supabase
      .from('batches')
      .update({
        name, description,
        start_date: startDate, end_date: endDate,
        start_time: startTime, end_time: endTime,
        faculty_id: facultyId || null, skill_id: skillId || null,
        max_students: maxStudents, days_of_week: daysOfWeek,
        status,
      })
      .eq('id', id)
      .select(`*, faculty:faculty_id(*), skill:skill_id(*), students:batch_students(students(*))`)
      .single();

    if (error) throw error;
    
    const formattedBatch = { ...data, students: data.students.map(s => s.students).filter(Boolean) };
    await logActivity('updated', `batch ${formattedBatch.name}`, 'Admin');
    res.json(formattedBatch);
  } catch (error) {
    // --- MODIFIED --- Updated error message for new schema's unique constraint
    if (error.code === '23505' && error.message.includes('batches_name_location_key')) {
      return res.status(409).json({ error: `A batch with the name '${name}' already exists at this location.` });
    }
     if (error.code === '23503') {
      if (error.message.includes('batches_faculty_id_fkey')) return res.status(400).json({ error: `Faculty with ID ${facultyId} does not exist.` });
      if (error.message.includes('batches_skill_id_fkey')) return res.status(400).json({ error: `Skill with ID ${skillId} does not exist.` });
      if (error.message.includes('batch_students_student_id_fkey')) return res.status(400).json({ error: 'One or more student IDs are invalid.' });
    }
    res.status(500).json({ error: error.message });
  }
};


const deleteBatch = async (req, res) => {
  // NO CHANGE NEEDED. Deleting by a unique 'id' (UUID) is safe.
  const { id } = req.params;
  try {
    const { error } = await supabase.from('batches').delete().eq('id', id);
    if (error) throw error;
    await logActivity('deleted', `batch with id ${id}`, 'Admin');
    res.status(204).send();
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
};


/**
 * ✅ Standardized transformation logic (Hybrid Support)
 * * Logic A (Modern): If Admission Number starts with 'RVM-'
 * 1. Priority: If total_due <= 0 -> 'FULL PAID'
 * 2. Priority: If balance > 0 and next_task_due_date exists -> formatted Date
 * 3. Fallback: Manual remark from student table
 * * Logic B (Legacy): If Admission Number is purely numeric
 * - Directly show the exact manual 'remarks' written by admin
 */
const transformStudentData = (student) => {
  if (!student) return null;

  const admissionNo = (student.admission_number || "").trim();
  const followData = Array.isArray(student.follow_up) 
    ? student.follow_up[0] 
    : student.follow_up;
  
  const balance = followData ? Number(followData.total_due || 0) : 0;
  const nextDate = followData?.next_task_due_date;
  
  let dynamicRemark = '';

  // ✅ LOGIC A: Modern Students (e.g., RVM-2026-0093)
  if (admissionNo.startsWith('RVM-')) {
    // Priority 1: Check Financial Balance first
    if (balance <= 0) {
      dynamicRemark = 'FULL PAID';
    } 
    // Priority 2: If money is owed, check for the next automated due date
    else if (nextDate) {
      const d = new Date(nextDate);
      if (!isNaN(d.getTime())) {
        // Formats to "05 Feb 2026"
        dynamicRemark = `${String(d.getDate()).padStart(2, '0')} ${d.toLocaleString('en-GB', { month: 'short' })} ${d.getFullYear()}`;
      } else {
        dynamicRemark = 'Date Pending';
      }
    }
    // Priority 3: Fallback for RVM students if no follow-up record exists
    else {
      dynamicRemark = student.remarks || 'No Remark';
    }
  } 
  // ✅ LOGIC B: Legacy Students (e.g., 4270, 2194)
  else {
    // Show the exact remark that was manually entered by the admin
    dynamicRemark = student.remarks || 'No Remark';
  }

  return { 
    ...student, 
    name: student.name?.trim(), // Clean up whitespace/tabs
    remarks: dynamicRemark,
    total_due_amount: balance,
    follow_up: followData 
  };
};

const getBatchStudents = async (req, res) => {
  const { id } = req.params; // batch_id
  try {
    const { data: studentLinks, error } = await supabase
      .from('batch_students')
      .select(`
        student_id,
        students:student_id (
          *,
          admission:admissions (
            id,
            batch_preference,
            joined,
            total_invoice_amount
          ),
          follow_up:v_follow_up_task_list (
            next_task_due_date,
            total_due,
            task_count
          ),
          batch_count:batch_students(count)
        )
      `)
      .eq('batch_id', id);

    if (error) throw error;

    const processedStudents = studentLinks.map(item => {
      const s = item.students;
      if (!s) return null;

      // Use your existing transformer but add the new course/batch context
      const transformed = transformStudentData(s); 
      
      return {
        ...transformed,
        // ✅ NEW: Courses assigned in Admission (from batch_preference or courses table if joined)
        enrolled_courses: s.admission?.[0]?.batch_preference || "N/A",
        // ✅ NEW: Count of batches this student is currently in
        active_batches_count: s.batch_count?.[0]?.count || 0,
        admission_status: s.admission?.[0]?.joined ? "Joined" : "Pending"
      };
    }).filter(Boolean);

    res.json(processedStudents);
  } catch (error) {
    console.error("Error in getBatchStudents:", error);
    res.status(500).json({ error: error.message });
  }
};

const getActiveStudentsCount = async (req, res) => {
  const isSuperAdmin = req.isSuperAdmin;
  const userLocationId = req.locationId;
  const { location_id } = req.query;

  if (!userLocationId && !isSuperAdmin) {
    return res.status(401).json({ error: 'Authentication required with location context.' });
  }
  
  try {
    const now = new Date().toISOString();
    let targetLocationId = null;

    if (isSuperAdmin) {
      if (location_id && location_id !== 'all') targetLocationId = Number(location_id);
    } else {
      targetLocationId = Number(userLocationId);
    }

    let query = supabase.from("batches").select("id").lte('start_date', now).gte('end_date', now);

    if (targetLocationId) {
      query = query.eq('location_id', targetLocationId);
    }

    const { data: activeBatches, error: batchesError } = await query;
    if (batchesError) throw batchesError;

    if (!activeBatches || activeBatches.length === 0) {
      return res.status(200).json({ total_active_students: 0, active_batches_count: 0 });
    }

    const activeBatchIds = activeBatches.map((b) => b.id);
    const { data: studentLinks, error: studentLinksError } = await supabase
      .from("batch_students")
      .select("student_id")
      .in("batch_id", activeBatchIds);

    if (studentLinksError) throw studentLinksError;

    const uniqueStudentIds = new Set((studentLinks || []).map((link) => link.student_id));

    res.status(200).json({ 
      total_active_students: uniqueStudentIds.size,
      active_batches_count: activeBatchIds.length 
    });

  } catch (error) {
    console.error('Error in getActiveStudentsCount:', error);
    res.status(500).json({ error: 'Failed to calculate metrics.' });
  }
};


const getRemarkHistory = async (req, res) => {
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
    res.status(500).json({ error: 'Failed to fetch history' });
  }
};

module.exports = {
  getAllBatches,
  createBatch,
  updateBatch,
  deleteBatch,
  getBatchStudents,
  getActiveStudentsCount,
  getRemarkHistory,
};