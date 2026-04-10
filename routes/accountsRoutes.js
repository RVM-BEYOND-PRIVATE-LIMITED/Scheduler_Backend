// routes/accountsRoutes.js
const express = require('express');
const router = express.Router();
const {
  getAdmissionsForAccounts, // Renamed
  approveAdmission,
  rejectAdmission,
  recordPayment,
  getAccountDetails,
  uploadAdmissionDocuments,
  getReceiptData,
  updateAdmissionRemarks
} = require('../controllers/accountsController');
const auth = require('../middleware/auth');

// GET /api/accounts/admissions?status=Pending (For Approval Page)
// GET /api/accounts/admissions?status=Approved (For Accounts Page)
router.get('/admissions', auth, getAdmissionsForAccounts);

// GET /api/accounts/admissions/:admissionId (NEW consolidated details)
router.get('/admissions/:admissionId', auth, getAccountDetails);

// PATCH /api/accounts/admissions/:admissionId/approve
router.patch('/admissions/:admissionId/approve', auth, approveAdmission);

// PATCH /api/accounts/admissions/:admissionId/reject
router.patch('/admissions/:admissionId/reject', auth, rejectAdmission);

// POST /api/accounts/payments (Record a new payment)
router.post('/payments', auth, recordPayment);

// GET /api/accounts/payments/:paymentId/receipt
router.get('/payments/:paymentId/receipt', auth, getReceiptData);

router.post('/admissions/:admissionId/upload-docs', auth, uploadAdmissionDocuments);

// PATCH /api/accounts/admissions/:admissionId/remarks
router.patch('/admissions/:admissionId/remarks', auth, updateAdmissionRemarks);

module.exports = router;