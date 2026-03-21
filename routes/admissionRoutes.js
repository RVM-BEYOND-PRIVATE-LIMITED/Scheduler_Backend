// server/routes/admissionRoutes.js
const express = require('express');
const router = express.Router();
const auth = require('../middleware/auth');

const {
  getAllAdmissions,
  getAdmissionById,
  createAdmission,
  updateAdmission,
  checkAdmissionByPhone,
  markStudentDropout, // ✅ NEW: Import the dropout controller
} = require('../controllers/admissionController');

/* -------------------- UNDERTAKING LOOKUP (PUBLIC) -------------------- */
router.get('/by-phone/:phone', checkAdmissionByPhone);

/* -------------------- ADMISSIONS (PROTECTED) -------------------- */
router.get('/', auth, getAllAdmissions);
router.post('/', auth, createAdmission);
router.get('/:id', auth, getAdmissionById);
router.put('/:id', auth, updateAdmission);

// ✅ NEW: Route to mark a student as a Dropout
router.put('/:id/dropout', auth, markStudentDropout);
router.put('/:id/toggle-undertaking', auth, toggleUndertakingStatus);

module.exports = router;