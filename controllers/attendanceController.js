
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
    const formattedDate = date.substring(0, 10);
    const records = attendance.map(item => ({
      batch_id: batchId,
      student_id: item.student_id,
      date: formattedDate,
      is_present: item.is_present,
    }));
    const { data, error } = await supabase.from('student_attendance').upsert(records, { onConflict: ['batch_id', 'student_id', 'date'] }).select();
    if (error) throw error;
    res.status(201).json(data);
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
};

const getDailyAttendanceForBatch = async (req, res) => {
  const { batchId } = req.params;
  const { date } = req.query;
  if (!date) return res.status(400).json({ error: "A 'date' query parameter is required." });
  try {
    const formattedDate = date.substring(0, 10);
    const { data, error } = await supabase.from('student_attendance').select('*, student:students(*)').eq('batch_id', batchId).eq('date', formattedDate);
    if (error) throw error;
    res.status(200).json(data);
  } catch (error) {
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
    const [
      { data: batchInfo, error: batchError },
      { data: studentLinks, error: studentError },
      { data: attendanceRecords, error: attendanceError }
    ] = await Promise.all([
      supabase.from('batches').select('start_date, end_date, schedule').eq('id', batchId).single(),
      supabase.from('batch_students')
        .select(`
          student_id,
          students:student_id (
            *,
            follow_up:v_follow_up_task_list (
              next_task_due_date,
              total_due,
              task_count
            )
          )
        `)
        .eq('batch_id', batchId),
      supabase.from('student_attendance')
        .select('student_id, date, is_present')
        .eq('batch_id', batchId)
        .gte('date', startDate)
        .lte('date', endDate)
    ]);

    if (batchError || studentError || attendanceError) throw (batchError || studentError || attendanceError);
    if (!studentLinks || studentLinks.length === 0) return res.status(404).json({ error: 'No students found for this batch.' });

    // 1. Generate strictly valid schedule dates
    const expectedDates = typeof getExpectedSessionDates === 'function' 
      ? getExpectedSessionDates(startDate, endDate, batchInfo.schedule)
      : [];

    // 2. Filter attendance records to ONLY include days that match the schedule
    // This ignores "extra" logs marked on wrong days.
    const validAttendanceRecords = attendanceRecords.filter(record => 
      expectedDates.includes(record.date)
    );

    // 3. Process students (Logic remains same)
    const processedStudents = studentLinks.map(link => {
      const student = link.students;
      if (!student) return null;
      const admissionNo = (student.admission_number || "").trim();
      const followData = Array.isArray(student.follow_up) ? student.follow_up[0] : student.follow_up;
      const balance = followData ? Number(followData.total_due || 0) : 0;
      const nextDate = followData?.next_task_due_date;
      
      let dynamicRemark = '';
      if (admissionNo.startsWith('RVM-')) {
        if (balance <= 0) dynamicRemark = 'FULL PAID';
        else if (nextDate) {
          const d = new Date(nextDate);
          dynamicRemark = !isNaN(d.getTime()) 
            ? `${String(d.getDate()).padStart(2, '0')} ${d.toLocaleString('en-GB', { month: 'short' })} ${d.getFullYear()}`
            : 'Date Pending';
        } else dynamicRemark = student.remarks || 'No Remark';
      } else {
        dynamicRemark = student.remarks || 'No Remark';
      }

      return {
        id: student.id,
        name: student.name?.trim() || 'Unknown',
        admission_number: student.admission_number || 'N/A',
        phone_number: student.phone_number || '',
        remarks: dynamicRemark,
        total_due_amount: balance,
        is_defaulter: !!student.is_defaulter 
      };
    }).filter(Boolean);

    // 4. Compliance Calculations using ONLY valid dates
    const markedDates = [...new Set(validAttendanceRecords.map(r => r.date))];
    const missingDates = expectedDates.filter(d => !markedDates.includes(d));

    const attendance_by_date = validAttendanceRecords.reduce((acc, record) => {
      const dateKey = record.date;
      if (!acc[dateKey]) acc[dateKey] = [];
      acc[dateKey].push({ student_id: record.student_id, is_present: record.is_present });
      return acc;
    }, {});

    res.status(200).json({ 
      students: processedStudents, 
      attendance_by_date, 
      compliance: {
        missing_attendance_dates: missingDates,
        expected_days_count: expectedDates.length,
        marked_days_count: markedDates.length // Now correctly reflects only valid schedule days
      }
    });
  } catch (error) {
    console.error("Batch Report Error:", error);
    res.status(500).json({ error: error.message });
  }
};
/**
 * UPDATED: Single Faculty Audit Report (Location & Role Aware)
 * Scopes data by branch for standard admins; global access for Super Admins.
 */
const getFacultyAttendanceReport = async (req, res) => {
  const { facultyId } = req.params;
  const { startDate, endDate, location_id } = req.query; // ✅ location_id added for Super Admin filtering
  const userLocationId = req.locationId ? Number(req.locationId) : null;
  const isSuperAdmin = req.isSuperAdmin;

  if (!startDate || !endDate) {
    return res.status(400).json({ error: "Start date and end date are required for the audit." });
  }

  try {
    // 1. Fetch Faculty Data (Verify they exist)
    const { data: facultyData } = await supabase
      .from('faculty')
      .select('id, name')
      .eq('id', facultyId)
      .single();

    if (!facultyData) return res.status(404).json({ error: "Faculty not found" });

    /* -------------------- 🛡️ LOCATION LOGIC -------------------- */
    // Determine the target location filter
    let targetLocationId = null;
    if (isSuperAdmin) {
      // Super Admin can focus on a specific branch or leave null for global audit
      if (location_id && location_id !== 'all') targetLocationId = Number(location_id);
    } else {
      // Standard Admin is hard-locked to their branch
      if (!userLocationId) return res.status(401).json({ error: "Location context missing." });
      targetLocationId = userLocationId;
    }

    // 2. Fetch involved batches (Permanent + Substitutions)
    // ✅ Applied location filter to the permanent batches query
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

    // 3. Fetch full context data within range
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
    let globalPossibleGlobal = 0;

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
      const sessionCount = markedDates.length;
      
      const maxPossibleMarks = studentCount * sessionCount;
      const actualPresentCount = relevantAttendance.filter(a => a.is_present).length;
      const cappedPresentCount = Math.min(actualPresentCount, maxPossibleMarks);
      
      const missingDates = expectedDates.filter(d => !markedDates.includes(d));

      totalPresentGlobal += cappedPresentCount;
      globalPossibleGlobal += maxPossibleMarks;

      return {
        batch_id: batch.id,
        batch_name: batch.name,
        status: getDynamicStatus(batch.start_date, batch.end_date),
        student_count: studentCount,
        total_sessions: sessionCount,
        attendance_percentage: maxPossibleMarks > 0 
            ? parseFloat(((cappedPresentCount / maxPossibleMarks) * 100).toFixed(2)) 
            : 0,
        compliance: { missing_attendance_dates: missingDates, is_complete: missingDates.length === 0 }
      };
    });

    res.status(200).json({
      faculty_id: facultyId,
      faculty_name: facultyData.name,
      faculty_attendance_percentage: globalPossibleGlobal > 0 
        ? parseFloat(((totalPresentGlobal / globalPossibleGlobal) * 100).toFixed(2)) 
        : 0,
      batches: batchReports,
      missing_logs: batchReports
        .filter(b => !b.compliance.is_complete)
        .map(b => ({ batch_name: b.batch_name, count: b.compliance.missing_attendance_dates.length }))
    });
  } catch (error) {
    console.error("Faculty Report Filter Error:", error);
    res.status(500).json({ error: error.message });
  }
};
const getOverallAttendanceReport = async (req, res) => {
  try {
    const { startDate, endDate, location_id } = req.query; // ✅ location_id added for Super Admin filtering
    const userLocationId = req.locationId ? Number(req.locationId) : null;
    const isSuperAdmin = req.isSuperAdmin;

    // Safety Check: Required for accurate compliance math
    if (!startDate || !endDate) {
      return res.status(400).json({ error: "Start date and end date are required for the audit." });
    }

    /* -------------------- 🛡️ LOCATION BIFURCATION LOGIC -------------------- */
    let targetLocationId = null;
    if (isSuperAdmin) {
      // Super Admin: Can filter by specific city or audit the entire organization
      if (location_id && location_id !== 'all' && location_id !== 'All') {
        targetLocationId = Number(location_id);
      }
    } else {
      // Standard Admin: Strictly restricted to their branch context
      if (!userLocationId) return res.status(401).json({ error: 'Location context missing.' });
      targetLocationId = userLocationId;
    }

    // 1. Fetch base data based on Location Context
    let facultyQuery = supabase.from("faculty").select("id, name, location_id");
    let batchQuery = supabase.from("batches").select("id, name, faculty_id, start_date, end_date, schedule, location_id");

    // Apply location filter only if targetLocationId is set (locks standard admins)
    if (targetLocationId) {
      facultyQuery = facultyQuery.eq('location_id', targetLocationId);
      batchQuery = batchQuery.eq('location_id', targetLocationId);
    }

    const [facultiesRes, batchesRes] = await Promise.all([facultyQuery, batchQuery]);

    const faculties = facultiesRes.data || [];
    const batchesData = batchesRes.data || [];

    // Filter only active batches within the system
    const activeBatches = batchesData.filter(b => getDynamicStatus(b.start_date, b.end_date) === "active");
    
    if (activeBatches.length === 0) {
      return res.json({ overall_attendance_percentage: 0, faculty_reports: [] });
    }

    const activeBatchIds = activeBatches.map(b => b.id);

    // 2. Fetch all range-specific audit records
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
    
    // 3. Initialize Faculty metrics
    const facultyStats = faculties.reduce((acc, f) => ({ 
      ...acc, 
      [f.id]: { id: f.id, name: f.name, batchStats: {} } 
    }), {});

    // 4. Process Attendance (Date-Specific Acting Faculty Check)
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
                stats.batchStats[record.batch_id] = { presentCount: 0, dates: new Set() };
            }
            if (record.is_present) stats.batchStats[record.batch_id].presentCount++;
            stats.batchStats[record.batch_id].dates.add(record.date);
        }
    });

    let globalTotalPresent = 0;
    let globalTotalPossible = 0;

    // 5. Generate Individual Faculty Reports
    const facultyReports = Object.keys(facultyStats).map(fId => {
        const stats = facultyStats[fId];
        const missingLogs = [];
        const batchBreakdown = [];
        let facultyPresent = 0;
        let facultyPossible = 0;

        activeBatches.forEach(batch => {
            const bData = stats.batchStats[batch.id];
            const markedDates = Array.from(bData?.dates || []);
            const sessionCount = markedDates.length;
            const isPrimary = batch.faculty_id === fId;
            const hasMarkedData = sessionCount > 0;

            if (isPrimary || hasMarkedData) {
                const studentCount = batchStudentCounts[batch.id] || 0;
                const maxPossibleForThisBatch = studentCount * sessionCount;
                const cappedPresentCount = Math.min(bData?.presentCount || 0, maxPossibleForThisBatch);
                
                facultyPresent += cappedPresentCount;
                facultyPossible += maxPossibleForThisBatch;

                const auditStart = new Date(startDate) > new Date(batch.start_date) ? startDate : batch.start_date;
                const auditEnd = new Date(endDate) < new Date(batch.end_date) ? endDate : batch.end_date;
                
                const expectedDates = getExpectedSessionDates(auditStart, auditEnd, batch.schedule);
                const missing = expectedDates.filter(d => !markedDates.includes(d));

                batchBreakdown.push({
                    batch_id: batch.id,
                    batch_name: batch.name,
                    student_count: studentCount,
                    total_sessions: sessionCount,
                    attendance_percentage: maxPossibleForThisBatch > 0 
                        ? parseFloat(((cappedPresentCount / maxPossibleForThisBatch) * 100).toFixed(2)) 
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

    // 6. Return Overall Weighted Average
    res.status(200).json({ 
        overall_attendance_percentage: globalTotalPossible > 0 
            ? parseFloat(((globalTotalPresent / globalTotalPossible) * 100).toFixed(2)) 
            : 0,
        faculty_reports: facultyReports.sort((a, b) => a.faculty_name.localeCompare(b.faculty_name))
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