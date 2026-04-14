
const supabase = require("../db.js");
/**
 * NEW HELPER: Generates a list of dates a batch WAS SUPPOSED to have class
 * from start_date up to 'today' (or batch end_date).
 * Default schedule is Mon-Sat (1,2,3,4,5,6).
 */
/**
 * RIGID HELPER: Generates class dates based strictly on the provided schedule.
 * If scheduleDays is empty or missing, it returns NO dates (prevents false counting).
 */
const getExpectedSessionDates = (startDate, endDate, scheduleDays) => {
  // 1. Safety check: If no schedule is provided, return empty (don't assume Mon-Sat)
  if (!scheduleDays || !Array.isArray(scheduleDays) || scheduleDays.length === 0) {
    return [];
  }

  const dates = [];
  
  // 2. Normalize current and end boundaries to start of day (UTC/Local consistency)
  let current = new Date(startDate);
  current.setHours(0, 0, 0, 0);

  const today = new Date();
  today.setHours(0, 0, 0, 0);

  const batchEnd = new Date(endDate);
  batchEnd.setHours(0, 0, 0, 0);

  // We only count up to 'today' or the 'batch end', whichever comes first
  const finalBoundary = batchEnd > today ? today : batchEnd;

  // Convert scheduleDays to Numbers just in case they are strings from DB
  const validDays = scheduleDays.map(Number);

  while (current <= finalBoundary) {
    // getDay(): 0=Sun, 1=Mon, 2=Tue, 3=Wed, 4=Thu, 5=Fri, 6=Sat
    if (validDays.includes(current.getDay())) {
      dates.push(current.toISOString().split('T')[0]);
    }
    // Increment day safely
    current.setDate(current.getDate() + 1);
  }
  
  return dates;
};

const fetchAll = async (tableName, selectQuery) => {
  const allData = [];
  const pageSize = 1000;
  let page = 0;
  let moreDataAvailable = true;

  while (moreDataAvailable) {
    const from = page * pageSize;
    const to = from + pageSize - 1;

    const { data, error } = await supabase
      .from(tableName)
      .select(selectQuery)
      .range(from, to);

    if (error) {
      console.error(`Error fetching from ${tableName}:`, error);
      throw error;
    }

    if (data) {
      allData.push(...data);
    }

    if (!data || data.length < pageSize) {
      moreDataAvailable = false;
    }
    page++;
  }
  return allData;
};

function getDynamicStatus(startDate, endDate) {
  const now = new Date();
  const start = new Date(startDate);
  const end = new Date(endDate);
  now.setHours(0, 0, 0, 0);
  start.setHours(0, 0, 0, 0);
  end.setHours(0, 0, 0, 0);

  if (now < start) return "upcoming";
  if (now >= start && now <= end) return "active";
  return "completed";
}

// --- CONTROLLER FUNCTIONS ---

const addOrUpdateAttendance = async (req, res) => {
  const { batchId, date, attendance } = req.body;
  try {
    // ❌ OLD: date.substring(0, 10) or toISOString() 
    // ✅ NEW: Extract the literal date without timezone conversion
    const localDate = new Date(date);
    const formattedDate = `${localDate.getFullYear()}-${String(localDate.getMonth() + 1).padStart(2, '0')}-${String(localDate.getDate()).padStart(2, '0')}`;

    const records = attendance.map(item => ({
      batch_id: batchId,
      student_id: item.student_id,
      date: formattedDate, // Now strictly YYYY-MM-DD in Local Time
      is_present: item.is_present,
    }));

    const { data, error } = await supabase
      .from('student_attendance')
      .upsert(records, { onConflict: ['batch_id', 'student_id', 'date'] })
      .select();

    if (error) throw error;
    res.status(201).json(data);
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
};

const getDailyAttendanceForBatch = async (req, res) => {
  const { batchId } = req.params;
  const { date } = req.query; // e.g., "2026-03-24T02:00:00.000Z"
  
  if (!date) return res.status(400).json({ error: "A 'date' query parameter is required." });

  try {
    // ✅ FIX: Force the date to remain in Local Time (IST) before extracting the string
    const d = new Date(date);
    const formattedDate = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;

    // Fetch existing attendance AND the batch student list
    const [attendanceRes, studentsRes] = await Promise.all([
      supabase
        .from('student_attendance')
        .select('*, student:students(*)')
        .eq('batch_id', batchId)
        .eq('date', formattedDate),
      supabase
        .from('batch_students')
        .select('student:students(*)')
        .eq('batch_id', batchId)
    ]);

    if (attendanceRes.error) throw attendanceRes.error;
    if (studentsRes.error) throw studentsRes.error;

    // 1. If attendance already exists in DB for this LOCAL date, return it
    if (attendanceRes.data && attendanceRes.data.length > 0) {
      return res.status(200).json(attendanceRes.data);
    }

    // 2. RIGID LOGIC: If NO attendance is marked yet, return all students as "Absent"
    // This ensures the faculty starts with a clean "All Absent" slate for the correct day.
    const defaultAttendance = (studentsRes.data || []).map(link => ({
      batch_id: batchId,
      student_id: link.student.id,
      date: formattedDate,
      is_present: false, 
      student: link.student,
      is_placeholder: true 
    }));

    res.status(200).json(defaultAttendance);
  } catch (error) {
    console.error("Daily Attendance Fetch Error:", error);
    res.status(500).json({ error: error.message });
  }
};

const getBatchAttendanceReport = async (req, res) => {
  const { batchId } = req.params;
  const { startDate, endDate } = req.query;
  
  if (!batchId || !startDate || !endDate) {
    return res.status(400).json({ error: 'Batch ID, start date, and end date are required.' });
  }
  
  try {
    // 1. Fetch batch info and student links first
    const [
      { data: batchInfo, error: batchError },
      { data: studentLinks, error: studentError },
    ] = await Promise.all([
      supabase.from('batches').select('start_date, end_date, schedule').eq('id', batchId).single(),
      supabase.from('batch_students')
        .select(`
          student_id,
          students:student_id (*)
        `)
        .eq('batch_id', batchId)
    ]);

    if (batchError) throw batchError;
    if (studentError) throw studentError;

    const studentIds = (studentLinks || []).map(link => link.student_id);

    // 2. Fetch Follow-Up Task List AND attendance records
    const [
      { data: followUpData, error: followUpError },
      { data: attendanceRecords, error: attendanceError }
    ] = await Promise.all([
      // ✅ Now using your new view: v_follow_up_task_list
      supabase.from('v_follow_up_task_list').select('student_id, total_due, next_task_due_date').in('student_id', studentIds),
      supabase.from('student_attendance')
        .select('student_id, date, is_present')
        .eq('batch_id', batchId)
        .gte('date', startDate)
        .lte('date', endDate)
    ]);

    if (followUpError) throw followUpError;
    if (attendanceError) throw attendanceError;

    // 3. Create a quick lookup map for follow-up data
    const followUpMap = new Map((followUpData || []).map(item => [item.student_id, item]));

    const processedStudents = (studentLinks || []).map(link => {
      const student = link.students;
      if (!student) return null;

      const admissionNo = (student.admission_number || "").trim();
      
      // Pull true balance from the follow-up view
      const taskRecord = followUpMap.get(student.id);
      const balance = taskRecord ? parseFloat(taskRecord.total_due || 0) : parseFloat(student.total_due_amount || 0);

      // ✅ Dynamically assign the Remark to be the Next Task Due Date
      let displayRemark = student.remarks || "No Remark";
      
      if (balance <= 0) {
          // If they owe nothing, it's safer to override and say Paid
          displayRemark = "FULL PAID";
      } else if (taskRecord && taskRecord.next_task_due_date) {
          // Parse and format the SQL date (e.g., "2026-04-09") into something readable for the UI
          const d = new Date(taskRecord.next_task_due_date);
          if (!isNaN(d.getTime())) {
            displayRemark = `${String(d.getDate()).padStart(2, '0')} ${d.toLocaleString('en-GB', { month: 'short' })} ${d.getFullYear()}`;
          } else {
            // Fallback to raw string if JS Date parsing fails
            displayRemark = taskRecord.next_task_due_date; 
          }
      } else if (balance > 0) {
          // Edge Case: They owe money, but no follow-up task exists
          displayRemark = "Date Pending";
      }

      return {
        id: student.id,
        name: student.name?.trim() || 'Unknown',
        admission_number: admissionNo,
        phone_number: (student.phone_number || '').trim(),
        
        // 👇 Here is the updated remark containing the due date!
        remarks: displayRemark, 
        
        total_due_amount: balance,
        is_defaulter: !!student.is_defaulter,
        is_banned: !!student.is_banned,
        is_suspended: !!student.is_suspended,
        suspended_until: student.suspended_until
      };
    }).filter(Boolean);

    /* -------------------------------------------------------------------------- */
    /* 1. Generate strictly valid schedule dates                                  */
    /* -------------------------------------------------------------------------- */
    const expectedDates = getExpectedSessionDates(startDate, endDate, batchInfo.schedule);

    /* -------------------------------------------------------------------------- */
    /* 2. Map existing attendance for quick lookup                                */
    /* -------------------------------------------------------------------------- */
    const existingAttendanceMap = (attendanceRecords || []).reduce((acc, rec) => {
      if (!acc[rec.date]) acc[rec.date] = {};
      acc[rec.date][rec.student_id] = rec.is_present;
      return acc;
    }, {});

    /* -------------------------------------------------------------------------- */
    /* 3. Construct attendance_by_date including missing days                     */
    /* -------------------------------------------------------------------------- */
    const attendance_by_date = {};
    expectedDates.forEach(date => {
      attendance_by_date[date] = processedStudents.map(student => {
        const wasMarked = existingAttendanceMap[date] && existingAttendanceMap[date][student.id] !== undefined;
        return {
          student_id: student.id,
          is_present: wasMarked ? existingAttendanceMap[date][student.id] : false,
          is_auto_absent: !wasMarked 
        };
      });
    });

    res.status(200).json({ 
      students: processedStudents, 
      attendance_by_date,
      compliance: {
        expected_days_count: expectedDates.length,
        marked_days_count: Object.keys(existingAttendanceMap).length
      }
    });

  } catch (error) {
    console.error("Batch Report Error:", error);
    res.status(500).json({ error: error.message });
  }
};


const getFacultyAttendanceReport = async (req, res) => {
  const { facultyId } = req.params;
  const { startDate, endDate, location_id } = req.query; 
  const userLocationId = req.locationId ? Number(req.locationId) : null;
  const isSuperAdmin = req.isSuperAdmin;

  if (!startDate || !endDate) {
    return res.status(400).json({ error: "Start date and end date are required for the audit." });
  }

  try {
    const { data: facultyData } = await supabase
      .from('faculty')
      .select('id, name')
      .eq('id', facultyId)
      .single();

    if (!facultyData) return res.status(404).json({ error: "Faculty not found" });

    let targetLocationId = null;
    if (isSuperAdmin) {
      if (location_id && location_id !== 'all') targetLocationId = Number(location_id);
    } else {
      if (!userLocationId) return res.status(401).json({ error: "Location context missing." });
      targetLocationId = userLocationId;
    }

    let permBatchQuery = supabase.from('batches').select('id').eq('faculty_id', facultyId);
    if (targetLocationId) {
      permBatchQuery = permBatchQuery.eq('location_id', targetLocationId);
    }

    const [permBatches, subRecords] = await Promise.all([
      permBatchQuery,
      supabase.from('faculty_substitutions').select('batch_id').eq('substitute_faculty_id', facultyId)
    ]);

    const involvedBatchIds = [
      ...new Set([
        ...(permBatches.data || []).map(b => b.id), 
        ...(subRecords.data || []).map(s => s.batch_id)
      ])
    ];
    
    if (involvedBatchIds.length === 0) {
      return res.json({ 
        faculty_id: facultyId, 
        faculty_name: facultyData.name, 
        faculty_attendance_percentage: 0, 
        batches: [], 
        missing_logs: [] 
      });
    }

    const [allBatches, studentLinks, attendanceRecords, substitutions] = await Promise.all([
      supabase.from('batches').select('id, name, faculty_id, start_date, end_date, schedule').in('id', involvedBatchIds),
      supabase.from('batch_students').select('batch_id').in('batch_id', involvedBatchIds),
      supabase.from('student_attendance').select('batch_id, date, is_present').in('batch_id', involvedBatchIds).gte('date', startDate).lte('date', endDate),
      supabase.from('faculty_substitutions').select('*').in('batch_id', involvedBatchIds)
    ]);

    const batchesToProcess = allBatches.data || [];
    const batchStudentCounts = studentLinks.data.reduce((acc, link) => ({ 
      ...acc, [link.batch_id]: (acc[link.batch_id] || 0) + 1 
    }), {});

    let totalPresentGlobal = 0;
    let totalPossibleGlobal = 0;

    const batchReports = batchesToProcess.map(batch => {
      const studentCount = batchStudentCounts[batch.id] || 0;
      const auditStart = new Date(startDate) > new Date(batch.start_date) ? startDate : batch.start_date;
      const auditEnd = new Date(endDate) < new Date(batch.end_date) ? endDate : batch.end_date;
      
      const expectedDates = getExpectedSessionDates(auditStart, auditEnd, batch.schedule);
      
      const relevantAttendance = attendanceRecords.data.filter(rec => {
        if (rec.batch_id !== batch.id) return false;
        const sub = substitutions.data.find(s => s.batch_id === batch.id && rec.date >= s.start_date && rec.date <= s.end_date);
        const actingFacultyId = sub ? sub.substitute_faculty_id : batch.faculty_id;
        return actingFacultyId === facultyId;
      });

      const markedDates = [...new Set(relevantAttendance.map(a => a.date))];
      
      // ✅ FIX: Protect against Division by Zero and Unscheduled classes
      const sessionCountForMath = Math.max(expectedDates.length, markedDates.length);
      const batchPossible = sessionCountForMath * studentCount;
      const actualPresentCount = relevantAttendance.filter(a => a.is_present).length;
      
      const missingDates = expectedDates.filter(d => !markedDates.includes(d));

      totalPresentGlobal += actualPresentCount;
      totalPossibleGlobal += batchPossible;

      return {
        batch_id: batch.id,
        batch_name: batch.name,
        status: getDynamicStatus(batch.start_date, batch.end_date),
        student_count: studentCount,
        expected_sessions: expectedDates.length,
        marked_sessions: markedDates.length,
        attendance_percentage: batchPossible > 0 
            ? parseFloat(((actualPresentCount / batchPossible) * 100).toFixed(2)) 
            : 0,
        compliance: { 
          missing_attendance_dates: missingDates, 
          is_complete: missingDates.length === 0 
        }
      };
    });

    res.status(200).json({
      faculty_id: facultyId,
      faculty_name: facultyData.name,
      faculty_attendance_percentage: totalPossibleGlobal > 0 
        ? parseFloat(((totalPresentGlobal / totalPossibleGlobal) * 100).toFixed(2)) 
        : 0,
      batches: batchReports,
      missing_logs: batchReports
        .filter(b => !b.compliance.is_complete)
        .map(b => ({ 
          batch_name: b.batch_name, 
          count: b.compliance.missing_attendance_dates.length 
        }))
    });
  } catch (error) {
    console.error("Faculty Report Filter Error:", error);
    res.status(500).json({ error: error.message });
  }
};

const getOverallAttendanceReport = async (req, res) => {
  try {
    const { startDate, endDate, location_id } = req.query;
    const userLocationId = req.locationId ? Number(req.locationId) : null;
    const isSuperAdmin = req.isSuperAdmin;

    if (!startDate || !endDate) {
      return res.status(400).json({ error: "Start date and end date are required for the audit." });
    }

    /* -------------------- 🛡️ LOCATION LOGIC -------------------- */
    let targetLocationId = null;
    if (isSuperAdmin) {
      if (location_id && !['all', 'All'].includes(location_id)) {
        targetLocationId = Number(location_id);
      }
    } else {
      if (!userLocationId) return res.status(401).json({ error: 'Location context missing.' });
      targetLocationId = userLocationId;
    }

    // 1. Fetch base data
    let facultyQuery = supabase.from("faculty").select("id, name, location_id");
    let batchQuery = supabase.from("batches").select("id, name, faculty_id, start_date, end_date, schedule, location_id");

    if (targetLocationId) {
      facultyQuery = facultyQuery.eq('location_id', targetLocationId);
      batchQuery = batchQuery.eq('location_id', targetLocationId);
    }

    const [facultiesRes, batchesRes] = await Promise.all([facultyQuery, batchQuery]);
    const faculties = facultiesRes.data || [];
    const batchesData = batchesRes.data || [];

    /* -------------------- 🎯 RIGID SCHEDULE FILTER -------------------- */
    // Filter batches to ONLY those that were supposed to run during the selected dates
    const activeBatches = batchesData.filter(batch => {
      const isStatusActive = getDynamicStatus(batch.start_date, batch.end_date) === "active";
      if (!isStatusActive) return false;

      // Check if this batch has any scheduled sessions within the user's selected range
      const auditStart = new Date(startDate) > new Date(batch.start_date) ? startDate : batch.start_date;
      const auditEnd = new Date(endDate) < new Date(batch.end_date) ? endDate : batch.end_date;
      
      const expectedDatesInRange = getExpectedSessionDates(auditStart, auditEnd, batch.schedule);
      
      // ✅ Only include if sessions were expected OR if they actually marked something (to capture extra classes)
      return expectedDatesInRange.length > 0;
    });
    
    if (activeBatches.length === 0) {
      return res.json({ 
        overall_attendance_percentage: 0, 
        faculty_reports: [],
        message: "No batches were scheduled for the selected date range." 
      });
    }

    const activeBatchIds = activeBatches.map(b => b.id);

    // 2. Fetch Audit Data
    const [substitutions, studentLinks, attendanceRecords] = await Promise.all([
        supabase.from("faculty_substitutions").select("*").in('batch_id', activeBatchIds),
        supabase.from("batch_students").select("batch_id").in('batch_id', activeBatchIds),
        supabase.from("student_attendance")
          .select("batch_id, date, is_present")
          .in('batch_id', activeBatchIds)
          .gte('date', startDate)
          .lte('date', endDate)
    ]);

    const batchStudentCounts = (studentLinks.data || []).reduce((acc, link) => {
        acc[link.batch_id] = (acc[link.batch_id] || 0) + 1;
        return acc;
    }, {});
    
    const facultyStats = faculties.reduce((acc, f) => ({ 
      ...acc, 
      [f.id]: { id: f.id, name: f.name, batchStats: {} } 
    }), {});

    // 3. Process Marked Attendance
    (attendanceRecords.data || []).forEach(record => {
        const batchDetails = activeBatches.find(b => b.id === record.batch_id);
        if (!batchDetails) return;

        const subs = (substitutions.data || []).filter(s => s.batch_id === record.batch_id);
        let actingId = batchDetails.faculty_id;
        const activeSub = subs.find(s => record.date >= s.start_date && record.date <= s.end_date);
        if (activeSub) actingId = activeSub.substitute_faculty_id;

        if (facultyStats[actingId]) {
            const stats = facultyStats[actingId];
            if (!stats.batchStats[record.batch_id]) {
                stats.batchStats[record.batch_id] = { presentCount: 0, markedDates: new Set() };
            }
            if (record.is_present) stats.batchStats[record.batch_id].presentCount++;
            stats.batchStats[record.batch_id].markedDates.add(record.date);
        }
    });

    let globalTotalPresent = 0;
    let globalTotalPossible = 0;

    // 4. Generate Faculty Reports
    const facultyReports = Object.keys(facultyStats).map(fId => {
        const stats = facultyStats[fId];
        const missingLogs = [];
        const batchBreakdown = [];
        let facultyPresent = 0;
        let facultyPossible = 0;

        activeBatches.forEach(batch => {
            const isPrimary = batch.faculty_id === fId;
            const bData = stats.batchStats[batch.id];
            const markedDates = Array.from(bData?.markedDates || []);
            const studentCount = batchStudentCounts[batch.id] || 0;

            if (isPrimary || markedDates.length > 0) {
                const auditStart = new Date(startDate) > new Date(batch.start_date) ? startDate : batch.start_date;
                const auditEnd = new Date(endDate) < new Date(batch.end_date) ? endDate : batch.end_date;
                
                const expectedDates = getExpectedSessionDates(auditStart, auditEnd, batch.schedule);
                
                // ✅ FIX: Use Math.max to prevent percentages over 100% (Division by Zero Protection)
                const sessionCountForMath = Math.max(expectedDates.length, markedDates.length);
                const batchPossible = sessionCountForMath * studentCount;
                const batchPresent = bData?.presentCount || 0;

                facultyPresent += batchPresent;
                facultyPossible += batchPossible;

                const missing = expectedDates.filter(d => !markedDates.includes(d));

                batchBreakdown.push({
                    batch_id: batch.id,
                    batch_name: batch.name,
                    student_count: studentCount,
                    expected_sessions: expectedDates.length,
                    marked_sessions: markedDates.length,
                    attendance_percentage: batchPossible > 0 
                        ? parseFloat(((batchPresent / batchPossible) * 100).toFixed(2)) 
                        : 0
                });

                if (isPrimary && missing.length > 0) {
                    missingLogs.push({ batch_name: batch.name, count: missing.length });
                }
            }
        });

        globalTotalPresent += facultyPresent;
        globalTotalPossible += facultyPossible;

        return {
            faculty_id: stats.id,
            faculty_name: stats.name,
            faculty_attendance_percentage: facultyPossible > 0 
                ? parseFloat(((facultyPresent / facultyPossible) * 100).toFixed(2)) 
                : 0,
            missing_logs: missingLogs,
            batches: batchBreakdown 
        };
    });

    // 5. Final Calculation
    res.status(200).json({ 
        overall_attendance_percentage: globalTotalPossible > 0 
            ? parseFloat(((globalTotalPresent / globalTotalPossible) * 100).toFixed(2)) 
            : 0,
        faculty_reports: facultyReports
          .filter(f => f.batches.length > 0) // Hide faculties with no classes today
          .sort((a, b) => a.faculty_name.localeCompare(b.faculty_name))
    });

  } catch (error) {
    console.error("Overall Report Logic Error:", error);
    res.status(500).json({ error: error.message });
  }
};


module.exports = {
  addOrUpdateAttendance,
  getDailyAttendanceForBatch,
  getBatchAttendanceReport,
  getFacultyAttendanceReport,
  getOverallAttendanceReport,
};