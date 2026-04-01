const supabase = require('../db');
const { format } = require('date-fns');

/**
 * @description Get the task list for the main follow-up dashboard.
 * UPDATED: Strictly excludes students formally marked as dropouts using the boolean flag.
 */
exports.getFollowUpTasks = async (req, res) => {
  const { dateFilter, searchTerm, batchName, assignedTo, dueAmountMin, startDate, endDate } = req.query;
  const locationId = req.locationId;
  const isSuperAdmin = req.isSuperAdmin; 

  try {
    const today = format(new Date(), 'yyyy-MM-dd');

    const buildBaseFilters = (q) => {
      // 1. Branch Security: SuperAdmins see everything, others see only their location
      if (!isSuperAdmin) {
        if (!locationId) throw new Error('LOCATION_REQUIRED');
        q = q.eq('location_id', locationId);
      }
      
      // 2. Task-First Logic: Only show records where money is still owed
      q = q.gt('total_due_amount', 0);

      // ✅ 3. DROPOUT FILTER: Strictly exclude dropouts from collection lists
      // This uses the is_dropout column we added to the v_follow_up_task_list view
      q = q.eq('is_dropout', false);
      
      // 4. Optional Search/Filters
      if (searchTerm) {
        q = q.or(`student_name.ilike.%${searchTerm}%,student_phone.ilike.%${searchTerm}%,admission_number.ilike.%${searchTerm}%`);
      }
      if (batchName) q = q.eq('batch_name', batchName);
      if (assignedTo) q = q.eq('assigned_to', assignedTo);
      if (dueAmountMin) q = q.gte('total_due_amount', dueAmountMin);
      
      return q;
    };

    // --- Part 1: Fetch Counts for Tab Badges ---
    const [todayRes, overdueRes, upcomingRes] = await Promise.all([
      buildBaseFilters(supabase.from('v_follow_up_task_list').select('*', { count: 'exact', head: true }))
        .eq('next_task_due_date', today)
        .or(`last_log_created_at.is.null,last_log_created_at.lt.${today}`),
      buildBaseFilters(supabase.from('v_follow_up_task_list').select('*', { count: 'exact', head: true }))
        .lt('next_task_due_date', today),
      buildBaseFilters(supabase.from('v_follow_up_task_list').select('*', { count: 'exact', head: true }))
        .gt('next_task_due_date', today)
    ]);

    // --- Part 2: Fetch Actual Data List ---
    let dataQuery = supabase.from('v_follow_up_task_list').select('*');
    dataQuery = buildBaseFilters(dataQuery);

    // Apply Tab-specific date logic
    if (dateFilter === 'today') {
      dataQuery = dataQuery.eq('next_task_due_date', today)
                           .or(`last_log_created_at.is.null,last_log_created_at.lt.${today}`);
    } else if (dateFilter === 'overdue') {
      dataQuery = dataQuery.lt('next_task_due_date', today);
    } else if (dateFilter === 'upcoming') {
      dataQuery = dataQuery.gt('next_task_due_date', today);
    }

    // Apply custom date range if selected (Advanced Filters)
    if (startDate) dataQuery = dataQuery.gte('next_task_due_date', startDate);
    if (endDate) dataQuery = dataQuery.lte('next_task_due_date', endDate);

    const { data, error } = await dataQuery.order('next_task_due_date', { ascending: true });

    if (error) throw error;

    res.status(200).json({
      tasks: data || [],
      counts: {
        today: todayRes.count || 0,
        overdue: overdueRes.count || 0,
        upcoming: upcomingRes.count || 0
      }
    });
  } catch (error) {
    console.error('Follow-up Fetch Error:', error);
    if (error.message === 'LOCATION_REQUIRED') {
      return res.status(403).json({ error: 'Unauthorized: No branch context provided.' });
    }
    res.status(500).json({ error: 'An unexpected error occurred.' });
  }
};

/**
 * @description Create a manual follow-up log.
 */
exports.createFollowUpLog = async (req, res) => {
  const { admission_id, notes, next_follow_up_date, type, lead_type } = req.body;
  const user_id = req.user?.id;
  const locationId = req.locationId;
  const isSuperAdmin = req.isSuperAdmin;

  if (!admission_id || !user_id) {
    return res.status(400).json({ error: 'Missing admission_id or user_id.' });
  }

  try {
    // 1. Resolve student location for security check
    const { data: admission, error: fetchErr } = await supabase
      .from('admissions')
      .select(`location_id, students (location_id)`)
      .eq('id', admission_id)
      .maybeSingle();

    if (fetchErr) throw fetchErr;
    if (!admission) return res.status(404).json({ error: "Admission not found." });

    const studentLocation = admission.location_id || (admission.students && admission.students.location_id);
    const isSameBranch = studentLocation && locationId && (Number(studentLocation) === Number(locationId));

    // 2. Security Gate: Super admin bypass
    if (!isSuperAdmin && !isSameBranch) {
      return res.status(403).json({ error: "Branch access restricted." });
    }

    // 3. Log the follow-up
    const { data: followUp, error: insertError } = await supabase
      .from('follow_ups')
      .insert({
        admission_id,
        user_id,
        notes: notes || '',
        follow_up_date: new Date().toISOString(), 
        next_follow_up_date: next_follow_up_date || null,
        type: type || 'Call',
        lead_type: lead_type || null
      })
      .select('*')
      .single();

    if (insertError) throw insertError;

    const { data: userData } = await supabase.from('users').select('username').eq('id', user_id).single();

    res.status(201).json({ 
      message: "Follow-up saved successfully.", 
      data: { ...followUp, staff_name: userData?.username || 'System' } 
    });
  } catch (error) {
    console.error('Error creating log:', error);
    res.status(500).json({ error: 'Failed to save follow-up log.' });
  }
};

/**
 * @description Get history for an admission.
 */
exports.getFollowUpHistoryForAdmission = async (req, res) => {
  const { admissionId } = req.params;
  try {
    const { data: logs, error: logsError } = await supabase
      .from('follow_up_details') 
      .select('*, user_id')
      .eq('admission_id', admissionId)
      .order('log_date', { ascending: false });

    if (logsError) throw logsError;

    const staffIds = [...new Set((logs || []).map(log => log.user_id).filter(Boolean))];
    let staffMap = {};

    if (staffIds.length > 0) {
      const { data: staffData } = await supabase.from('users').select('id, username').in('id', staffIds);
      staffData?.forEach(user => { staffMap[user.id] = user.username; });
    }

    const formattedHistory = (logs || []).map(log => ({
      ...log,
      staff_name: staffMap[log.user_id] || 'System' 
    }));

    res.status(200).json(formattedHistory);
  } catch (error) {
    console.error('Error fetching history:', error);
    res.status(500).json({ error: 'Failed to fetch history.' });
  }
};