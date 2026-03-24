const express = require('express');
const router = express.Router();
const supabase = require('../db'); // Added: Essential to fix the supabase reference error
const auth = require('../middleware/auth'); 

const { 
    getAllStudents, 
    createStudent, 
    updateStudent, 
    deleteStudent,
    setDefaulterStatus,
    getStudentBatches 
} = require('../controllers/studentsController');

// --- Standard CRUD Routes ---

router.get('/', auth, getAllStudents);
router.post('/', auth, createStudent);
router.put('/:id', auth, updateStudent);
router.delete('/:id', auth, deleteStudent);

// --- Defaulter Management Routes ---

/**
 * GET /api/students/:id/defaulter
 * FIXED: Uses maybeSingle() to prevent 500 errors when no record is found.
 */
router.get('/:id/defaulter', auth, async (req, res) => {
    try {
        const { data, error } = await supabase
            .from('students')
            .select('is_defaulter, defaulter_reason, admission_number')
            .eq('id', req.params.id)
            .maybeSingle(); // ✅ Change .single() to .maybeSingle()
        
        if (error) throw error;
        
        // If data is null, the ID is wrong or doesn't exist in the students table
        if (!data) {
            return res.status(404).json({ 
                error: "Student not found",
                details: "The ID provided does not exist in the students table." 
            });
        }

        res.json({ 
            is_defaulter: !!data.is_defaulter, 
            reason: data.defaulter_reason || "",
            has_admission_no: !!(data.admission_number && data.admission_number !== 'N/A')
        });
    } catch (err) {
        console.error("Error fetching defaulter status:", err.message);
        res.status(500).json({ error: "Internal Server Error" });
  }
});


/**
 * POST /api/students/:id/mark-defaulter
 * Uses the setDefaulterStatus controller to mark a student.
 */
router.post('/:id/mark-defaulter', auth, setDefaulterStatus);

/**
 * POST /api/students/:id/remove-defaulter
 * Injected middleware forces is_defaulter to false before hitting the controller.
 */
router.post('/:id/remove-defaulter', auth, (req, res, next) => {
    req.body.is_defaulter = false; 
    next();
}, setDefaulterStatus);

// --- Batch Routes ---

/**
 * GET /api/students/:id/batches
 * Fetches batches associated with a specific student.
 */
router.get('/:id/batches', auth, getStudentBatches);

module.exports = router;