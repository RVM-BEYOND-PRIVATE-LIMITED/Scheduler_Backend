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
  toggleUndertakingStatus,
  markStudentDropout,
  reactivateStudent,
  getDropoutRegistry,
} = require('../controllers/admissionController');

/* -------------------- PUBLIC LOOKUP -------------------- */
router.get('/by-phone/:phone', checkAdmissionByPhone);

/* -------------------- SPECIALIZED REGISTRIES -------------------- */
// ✅ MUST stay above /:id routes so "dropout-registry" isn't treated as an ID
router.get('/dropout-registry', auth, getDropoutRegistry);

/* -------------------- CORE ADMISSIONS -------------------- */
router.get('/', auth, getAllAdmissions);
router.post('/', auth, createAdmission);

/* -------------------- SPECIFIC RECORD ACTIONS -------------------- */
// Dynamic routes (/:id) should always be at the bottom
router.get('/:id', auth, getAdmissionById);
router.put('/:id', auth, updateAdmission);

// ✅ Reactivation & Dropout Actions
router.put('/:id/reactivate', auth, reactivateStudent);
router.put('/:id/dropout', auth, markStudentDropout);

// ✅ Undertaking Toggle
router.put('/:id/toggle-undertaking', auth, toggleUndertakingStatus);

module.exports = router;