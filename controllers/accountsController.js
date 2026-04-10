// controllers/accountsController.js
const supabase = require('../db');
const multer = require('multer');
const crypto = require('crypto');

// ✅ Multer configuration for memory storage
const storage = multer.memoryStorage();
const upload = multer({ 
  storage: storage,
  limits: { fileSize: 10 * 1024 * 1024 } 
}).array('files');

/**
 * @description Get admissions list for the approval page or general accounts view.
 * Scoped by location_id with a global override for roles with 'super_admin'.
 */
exports.getAdmissionsForAccounts = async (req, res) => {
  const { status = 'Approved', search = '', location_id } = req.query; 
  const userLocationId = req.locationId;
  const isSuperAdmin = req.isSuperAdmin; 

  try {
    let query = supabase
      .from('v_admission_financial_summary') 
      .select(`
        admission_number, 
        admission_id, 
        student_name, 
        student_phone_number, 
        created_at, 
        total_payable_amount, 
        total_paid, 
        remaining_due, 
        approval_status, 
        status, 
        base_amount, 
        location_id,
        courses_str,
        certificate_name,
        batch_name
      `);

    if (isSuperAdmin) {
      if (location_id && location_id !== 'all') {
        query = query.eq('location_id', Number(location_id));
      }
    } else {
      if (!userLocationId) return res.status(401).json({ error: 'Location context missing.' });
      query = query.eq('location_id', userLocationId);
    }

    if (status && status !== 'All') query = query.eq('approval_status', status);
    if (search) {
      query = query.or(`student_name.ilike.%${search}%,student_phone_number.ilike.%${search}%,admission_number.ilike.%${search}%`);
    }

    const { data, error } = await query.order('created_at', { ascending: false });
    if (error) throw error;

    const formattedData = data.map((adm) => ({
      admission_number: adm.admission_number,
      id: adm.admission_id,
      name: adm.student_name || 'N/A',
      admission_date: adm.created_at,
      total_payable_amount: adm.total_payable_amount,
      total_paid: adm.total_paid,
      balance: adm.remaining_due,
      approval_status: adm.approval_status,
      status: adm.status,
      phone_number: adm.student_phone_number || 'N/A',
      // ✅ New fields for frontend
      courses_str: adm.courses_str || 'N/A',
      certificate_name: adm.certificate_name || 'N/A',
      batch_name: adm.batch_name || 'Not Allotted',
      location_id: adm.location_id 
    }));

    res.status(200).json(formattedData);
  } catch (error) {
    res.status(500).json({ error: 'An unexpected error occurred.' });
  }
};
/**
 * @description Approve an admission.
 */
exports.approveAdmission = async (req, res) => {
  const { admissionId } = req.params;
  const { is_gst_exempt, gst_rate, finalAmountWithGST } = req.body;

  if (finalAmountWithGST === undefined || finalAmountWithGST < 0) {
    return res.status(400).json({ error: 'Final payable amount is required.' });
  }

  try {
    const { data: admissionData, error: fetchError } = await supabase
        .from('admissions')
        .select('final_payable_amount')
        .eq('id', admissionId)
        .single();

    if (fetchError || !admissionData) {
         return res.status(404).json({ error: 'Admission not found.' });
    }
    
    const taxableAmount = admissionData.final_payable_amount;
    const gstAmount = finalAmountWithGST - taxableAmount;

    const { data, error } = await supabase
      .from('admissions')
      .update({
        approval_status: 'Approved',
        rejection_reason: null,
        is_gst_exempt: is_gst_exempt,
        gst_rate: is_gst_exempt ? 0 : gst_rate,
        gst_amount: gstAmount,
        total_payable_amount: finalAmountWithGST
      })
      .eq('id', admissionId)
      .eq('approval_status', 'Pending') 
      .select('id')
      .single();

    if (error) throw error;

    if (!data) {
      return res.status(404).json({ error: 'Admission not found or not in Pending state.' });
    }

    res.status(200).json({ message: 'Admission approved successfully.', data });
  } catch (error) {
    console.error(`Error approving admission ${admissionId}:`, error);
    if (error.code === 'PGRST116') {
      return res.status(404).json({ error: 'Admission not found or not in Pending state.' });
    }
    res.status(500).json({ error: 'An unexpected error occurred.' });
  }
};


/**
 * @description Reject an admission.
 */
exports.rejectAdmission = async (req, res) => {
    const { admissionId } = req.params;
    const { rejection_reason } = req.body;

    if (!rejection_reason) {
        return res.status(400).json({ error: 'Rejection reason is required.' });
    }
    try {
        const { data, error } = await supabase
            .from('admissions')
            .update({
                approval_status: 'Rejected',
                rejection_reason: rejection_reason
            })
            .eq('id', admissionId)
            .eq('approval_status', 'Pending')
            .select('id')
            .single();

        if (error) throw error;
        if (!data) {
           return res.status(404).json({ error: 'Admission not found or not in Pending state.' });
        }
        res.status(200).json({ message: 'Admission rejected successfully.' });
    } catch (error) {
        console.error(`Error rejecting admission ${admissionId}:`, error);
        if (error.code === 'PGRST116') {
            return res.status(404).json({ error: 'Admission not found or not in Pending state.' });
        }
        res.status(500).json({ error: 'An unexpected error occurred.' });
    }
};

/**
 * Helper: Converts numeric amount to Indian Rupee Words
 */
const numToWords = (n) => {
  const a = ['', 'One ', 'Two ', 'Three ', 'Four ', 'Five ', 'Six ', 'Seven ', 'Eight ', 'Nine ', 'Ten ', 'Eleven ', 'Twelve ', 'Thirteen ', 'Fourteen ', 'Fifteen ', 'Sixteen ', 'Seventeen ', 'Eighteen ', 'Nineteen '];
  const b = ['', '', 'Twenty', 'Thirty', 'Forty', 'Fifty', 'Sixty', 'Seventy', 'Eighty', 'Ninety'];
  if ((n = n.toString()).length > 9) return 'Amount too large';
  let nArray = ('000000000' + n).substr(-9).match(/^(\d{2})(\d{2})(\d{2})(\d{1})(\d{2})$/);
  if (!nArray) return '';
  let str = '';
  str += (nArray[1] != 0) ? (b[nArray[1][0]] || a[nArray[1]]) + (b[nArray[1][0]] ? ' ' + a[nArray[1]] : '') + 'Crore ' : '';
  str += (nArray[2] != 0) ? (b[nArray[2][0]] || a[nArray[2]]) + (b[nArray[2][0]] ? ' ' + a[nArray[2]] : '') + 'Lakh ' : '';
  str += (nArray[3] != 0) ? (b[nArray[3][0]] || a[nArray[3]]) + (b[nArray[3][0]] ? ' ' + a[nArray[3]] : '') + 'Thousand ' : '';
  str += (nArray[4] != 0) ? a[nArray[4]] + 'Hundred ' : '';
  str += (nArray[5] != 0) ? ((str != '') ? 'and ' : '') + (b[nArray[5][0]] || a[nArray[5]]) + (b[nArray[5][0]] ? ' ' + a[nArray[5]] : '') : '';
  return str.trim() + ' Rupees Only';
};

/**
 * @description Record payment and sync across payments and receipts tables.
 * [UPDATED] Robust branch validation and automated installment balancing.
 */
// Inside controllers/accountsController.js

exports.recordPayment = async (req, res) => {
  const { admission_id, amount_paid, payment_date, method, notes } = req.body;
  const user_id = req.user?.id;
  const locationId = req.locationId; 
  const isSuperAdmin = req.isSuperAdmin;

  if (!admission_id || !amount_paid || !payment_date || !method || !user_id) {
    return res.status(400).json({ error: 'Missing required fields.' });
  }

  try {
    const { data: adm, error: admError } = await supabase
      .from('admissions')
      .select('location_id')
      .eq('id', admission_id)
      .single();

    if (admError || !adm) return res.status(404).json({ error: 'Admission not found.' });

    if (!isSuperAdmin && Number(adm.location_id) !== Number(locationId)) {
      return res.status(403).json({ error: 'Unauthorized: Branch mismatch.' });
    }

    // 🔥 UPDATED: Call the new financial year receipt generator
    const { data: receiptNumber, error: receiptError } = await supabase.rpc('generate_rvm_receipt_number');
    
    if (receiptError) {
        console.error("Receipt Generation Error:", receiptError);
        throw new Error('Failed to generate receipt number');
    }

    // 3. Insert payment record
    const { data: paymentData, error: paymentError } = await supabase
      .from('payments')
      .insert({
        admission_id,
        amount_paid: parseFloat(amount_paid),
        payment_date,
        method,
        receipt_number: receiptNumber, // New format: RVMBEYOND/2627/00001
        notes,
        created_by: user_id,
      })
      .select('id').single();

    if (paymentError) throw paymentError;

    // 4. Installment Balancing
    await supabase.rpc('apply_payment_to_installments', { p_payment_id: paymentData.id });

    // 5. Sync with Receipts table
    await supabase.from('receipts').insert({
        admission_id,
        receipt_number: receiptNumber,
        amount_paid: parseFloat(amount_paid),
        payment_date,
        payment_method: method,
        generated_by: user_id,
        location_id: adm.location_id
    });

    res.status(201).json({ 
      message: 'Payment recorded successfully.', 
      payment_id: paymentData.id, 
      receipt_number: receiptNumber 
    });
  } catch (error) {
    console.error('Payment Error:', error);
    res.status(500).json({ error: 'Failed to record payment.' });
  }
};

/**
 * @description Get details for the Accounts detail page.
 */
exports.getAccountDetails = async (req, res) => {
  const { admissionId } = req.params;
  const locationId = req.locationId; 
  const isSuperAdmin = req.isSuperAdmin; // ✅ Updated logic

  if (!admissionId || admissionId === 'undefined') {
    return res.status(400).json({ error: 'Invalid Admission ID.' });
  }

  try {
    const [
      admissionResult,
      installmentsResult,
      paymentsResult,
      coursesResult,
      intakeResult 
    ] = await Promise.all([
      supabase.from('admissions').select(`*, staff:admitted_by (username)`).eq('id', admissionId).single(),
      supabase.from('v_installment_status').select('id, due_date, amount_due, status').eq('admission_id', admissionId).order('due_date', { ascending: true }),
      supabase.from('payments').select('id, payment_date, amount_paid, method, receipt_number, notes, created_by').eq('admission_id', admissionId).order('payment_date', { ascending: true }),
      supabase.from('admission_courses').select('courses ( name )').eq('admission_id', admissionId),
      supabase.from('admission_intakes').select('identification_files').eq('admission_id', admissionId).maybeSingle()
    ]);

    if (admissionResult.error) throw admissionResult.error;
    const admission = admissionResult.data;

    // ✅ Security: Bypass location mismatch for super_admin
    if (!isSuperAdmin && Number(admission.location_id) !== Number(locationId)) {
      return res.status(403).json({ error: 'Access denied: Branch mismatch.' });
    }

    // --- DOCUMENT PATH EXTRACTION LOGIC ---
    let idCardUrls = [];
    const intakeFiles = intakeResult.data?.identification_files || [];
    const undertakingFiles = admission.undertaking_files || [];
    const combinedFiles = [...(Array.isArray(intakeFiles) ? intakeFiles : []), ...(Array.isArray(undertakingFiles) ? undertakingFiles : [])];

    if (combinedFiles.length > 0) {
      idCardUrls = combinedFiles.map(fileObj => {
        let storagePath = "";
        if (typeof fileObj === 'object' && fileObj !== null) {
          storagePath = fileObj.path || `intakes/${admissionId}/${fileObj.file_name}`;
        } else {
          storagePath = `intakes/${admissionId}/${fileObj}`;
        }
        if (!storagePath || storagePath.includes('[object Object]')) return null;

        const { data } = supabase.storage.from('identification').getPublicUrl(storagePath);
        return data.publicUrl;
      }).filter(Boolean);
    }

    // --- FALLBACK: Physical Folder Scan ---
    if (idCardUrls.length === 0) {
      const { data: storageFiles } = await supabase.storage.from('identification').list(`intakes/${admissionId}`);
      if (storageFiles && storageFiles.length > 0) {
        idCardUrls = storageFiles.filter(f => f.name !== '.emptyFolderPlaceholder').map(f => {
          const { data } = supabase.storage.from('identification').getPublicUrl(`intakes/${admissionId}/${f.name}`);
          return data.publicUrl;
        });
      }
    }

    const branchMap = { 1: "Faridabad", 2: "Pune", 3: "Ahmedabad" };
    const staffIds = [...new Set((paymentsResult.data || []).map(p => p.created_by).filter(Boolean))];
    const { data: userData } = await supabase.from('users').select('id, username').in('id', staffIds);
    const staffMap = {};
    (userData || []).forEach(u => { staffMap[u.id] = u.username; });

    const paymentsWithStaff = (paymentsResult.data || []).map(p => ({
      ...p,
      collected_by: staffMap[p.created_by] || 'System'
    }));

    res.status(200).json({
      name: admission.student_name,
      father_name: admission.father_name || 'N/A',
      phone: admission.student_phone_number,
      father_phone: admission.father_phone_number || 'N/A',
      address: admission.current_address || 'N/A',
      id_type: admission.identification_type || 'Aadhar Card',
      id_number: admission.identification_number || 'N/A',
      admission_date: admission.date_of_admission,
      admitted_by: admission.staff?.username || 'System',
      branch: branchMap[admission.location_id] || "Faridabad",
      total_fees: installmentsResult.data?.reduce((sum, i) => sum + Number(i.amount_due), 0) || 0,
      total_paid: paymentsWithStaff.reduce((sum, p) => sum + Number(p.amount_paid), 0) || 0,
      balance: (installmentsResult.data?.reduce((sum, i) => sum + Number(i.amount_due), 0) || 0) - (paymentsWithStaff.reduce((sum, p) => sum + Number(p.amount_paid), 0) || 0),
      installments: (installmentsResult.data || []).map(i => ({ id: i.id, due_date: i.due_date, amount: i.amount_due, status: i.status })),
      payments: paymentsWithStaff,
      courses: (coursesResult.data || []).map(c => c.courses?.name).filter(Boolean),
      documents: [...new Set(idCardUrls)],
      remarks: admission.admission_remarks || ''
    });
  } catch (error) {
    console.error(`Error fetching account details:`, error);
    res.status(500).json({ error: 'An unexpected server error occurred.' });
  }
};

/**
 * @description Update admission remarks (add/edit).
 */
exports.updateAdmissionRemarks = async (req, res) => {
  const { admissionId } = req.params;
  const { remarks } = req.body;
  const locationId = req.locationId;
  const isSuperAdmin = req.isSuperAdmin;

  if (remarks === undefined) {
    return res.status(400).json({ error: 'Remarks field is required.' });
  }

  try {
    const { data: admission, error: fetchError } = await supabase
      .from('admissions')
      .select('id, location_id')
      .eq('id', admissionId)
      .single();

    if (fetchError || !admission) {
      return res.status(404).json({ error: 'Admission not found.' });
    }

    if (!isSuperAdmin && Number(admission.location_id) !== Number(locationId)) {
      return res.status(403).json({ error: 'Access denied: Branch mismatch.' });
    }

    const { error: updateError } = await supabase
      .from('admissions')
      .update({ admission_remarks: remarks.trim(), updated_at: new Date().toISOString() })
      .eq('id', admissionId);

    if (updateError) throw updateError;

    res.status(200).json({ message: 'Remarks updated successfully.', remarks: remarks.trim() });
  } catch (error) {
    console.error(`Error updating remarks for admission ${admissionId}:`, error);
    res.status(500).json({ error: 'An unexpected server error occurred.' });
  }
};

/**
 * @description Get comprehensive data for receipt generation.
 * UPDATED: Includes full installment schedule for the student.
 */
exports.getReceiptData = async (req, res) => {
  const { paymentId } = req.params;
  const locationId = req.locationId; 
  const isSuperAdmin = req.isSuperAdmin; 

  if (!paymentId) return res.status(400).json({ error: 'Payment ID is required.' });

  try {
    const { data: payment, error: payError } = await supabase
      .from('payments')
      .select(`
        *,
        admissions!payments_admission_id_fkey (
          id, date_of_admission, gst_rate, is_gst_exempt, total_payable_amount,
          father_name, current_address, location_id,
          students ( name, phone_number, admission_number, batch_students ( batches ( name ) ) ),
          admission_courses ( courses ( name, price ) )
        )
      `)
      .eq('id', paymentId)
      .maybeSingle();

    if (payError || !payment || !payment.admissions) {
      return res.status(404).json({ error: 'Payment or associated admission not found.' });
    }

    const admissionData = payment.admissions;
    const studentData = admissionData.students;

    // ✅ Branch Security: Super admin bypass
    if (!isSuperAdmin && Number(admissionData.location_id) !== Number(locationId)) {
      return res.status(403).json({ error: 'Access denied: Branch mismatch.' });
    }

    // ✅ FIX: Fetch installments from v_installment_status (live computed view) instead of
    // the raw installments table. The raw table's 'status' column can be stale if
    // update_admission_full recreated installments after payments were recorded.
    // v_installment_status always derives status from cumulative payment totals.
    const { data: liveInstallments } = await supabase
      .from('v_installment_status')
      .select('id, due_date, amount_due, status')
      .eq('admission_id', admissionData.id)
      .order('due_date', { ascending: true });

    const installments = liveInstallments || [];

    // --- Next Due Prediction Logic ---
    const nextInst = installments
      .filter(i => i.status !== 'Paid')[0]; // already sorted by due_date

    // --- Installment Schedule for Receipt Table ---
    const installmentSchedule = installments.map(inst => ({
      due_date: inst.due_date,
      amount: inst.amount_due,
      status: inst.status,
    }));

    const batchString = studentData?.batch_students?.map(bs => bs.batches?.name).filter(Boolean).join(', ') || 'Not Allotted';

    // --- GST Calculation Logic ---
    let gstBreakdown = { cgst: 0, sgst: 0, totalGst: 0, rate: admissionData.gst_rate || 0 };
    let taxableAmount = Number(payment.amount_paid);
    
    if (!admissionData.is_gst_exempt && admissionData.gst_rate > 0) {
      const rateMultiplier = admissionData.gst_rate / 100;
      taxableAmount = payment.amount_paid / (1 + rateMultiplier);
      const totalGst = payment.amount_paid - taxableAmount;
      gstBreakdown = { cgst: totalGst / 2, sgst: totalGst / 2, totalGst, rate: admissionData.gst_rate };
    }

    const receiptData = {
      receipt_number: payment.receipt_number,
      payment_date: payment.payment_date,
      payment_method: payment.method,
      amount_paid: payment.amount_paid,
      amount_in_words: numToWords(Math.floor(payment.amount_paid)),
      notes: payment.notes,
      admission_id: admissionData.id,
      student_name: studentData?.name,
      student_phone: studentData?.phone_number,
      id_card_no: studentData?.admission_number,
      admission_batch: batchString,
      admission_date: admissionData.date_of_admission,
      father_name: admissionData.father_name || 'N/A',
      address: admissionData.current_address || 'N/A',
      courses: admissionData.admission_courses?.map(c => c.courses?.name).join(', ') || 'N/A',
      taxable_amount: taxableAmount.toFixed(2),
      gst_summary: gstBreakdown,
      total_payable_admission: admissionData.total_payable_amount,
      
      // ✅ NEW: Added the full installment plan
      installment_schedule: installmentSchedule,
      
      prediction: {
        next_due_date: nextInst ? nextInst.due_date : null,
        next_due_amount: nextInst ? nextInst.amount_due : 0,
        is_fully_paid: !nextInst
      }
    };

    res.status(200).json(receiptData);
  } catch (error) {
    console.error(`Error fetching receipt data:`, error);
    res.status(500).json({ error: 'Server error occurred.' });
  }
};



exports.uploadAdmissionDocuments = async (req, res) => {
  const { admissionId } = req.params;
  const user_id = req.user?.id; // Captured from auth middleware

  upload(req, res, async (err) => {
    if (err) return res.status(400).json({ error: 'File upload error' });
    
    const files = req.files;
    if (!files || files.length === 0) return res.status(400).json({ error: 'No files provided.' });

    try {
      // 1. Fetch current record using correct column 'undertaking_files'
      const { data: admission, error: fetchError } = await supabase
        .from('admissions')
        .select('id, undertaking_files') 
        .eq('id', admissionId)
        .single();

      if (fetchError || !admission) {
        console.error("DB Fetch Error:", fetchError);
        return res.status(404).json({ error: 'Admission record not found.' });
      }

      // ✅ Use 'undertaking_files' as the source
      const existingFiles = Array.isArray(admission.undertaking_files) ? admission.undertaking_files : [];
      const newFilesMetadata = [];

      // 2. Upload to Storage
      for (const file of files) {
        const safeName = file.originalname.replace(/[^a-zA-Z0-9.]/g, '_');
        const filePath = `intakes/${admissionId}/${crypto.randomUUID()}_${safeName}`;

        const { error: uploadError } = await supabase.storage
          .from('identification')
          .upload(filePath, file.buffer, {
            contentType: file.mimetype,
            upsert: true
          });

        if (uploadError) throw uploadError;

        const { data: urlData } = supabase.storage.from('identification').getPublicUrl(filePath);

        newFilesMetadata.push({
          file_name: file.originalname,
          path: filePath,
          url: urlData.publicUrl,
          uploaded_at: new Date().toISOString(),
          uploaded_by: user_id
        });
      }

      // 3. Update the table using 'undertaking_files' column
      const { error: updateError } = await supabase
        .from('admissions')
        .update({
          undertaking_files: [...existingFiles, ...newFilesMetadata],
          updated_at: new Date().toISOString()
        })
        .eq('id', admissionId);

      if (updateError) throw updateError;

      res.status(200).json({ 
        message: 'Vault updated successfully', 
        documents: newFilesMetadata 
      });

    } catch (error) {
      console.error('Vault Upload Error:', error);
      res.status(500).json({ error: 'Internal server error during upload.' });
    }
  });
};