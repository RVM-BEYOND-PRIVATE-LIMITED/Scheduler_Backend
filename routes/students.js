const express = require('express');
const router = express.Router();
const supabase = require('../db'); // Ensure this exports the initialized supabase client
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
 * FIXED: Advanced error logging to catch ID mismatches
 */
router.get('/:id/defaulter', auth, async (req, res) => {
    const rawId = req.params.id;
    
    // 🕵️‍♂️ DEBUG LOGS - Check your terminal/console when you get the error
    console.log("-----------------------------------------");
    console.log("DEFAULTER GET REQUEST FOR ID:", `[${rawId}]`);
    console.log("ID STRING LENGTH:", rawId?.length); 
    console.log("-----------------------------------------");

    try {
        // We use .trim() because hidden spaces in IDs are a common cause of 404s
        const cleanId = rawId.trim();

        const { data, error } = await supabase
            .from('students')
            .select('is_defaulter, defaulter_reason, admission_number')
            .eq('id', cleanId)
            .maybeSingle(); 
        
        if (error) {
            console.error("Supabase Query Error:", error.message);
            return res.status(400).json({ error: error.message });
        }
        
        if (!data) {
            return res.status(404).json({ 
                error: "Student record not found",
                details: `No record found for ID: ${cleanId}. Ensure this is the STUDENT UUID, not the ADMISSION UUID.` 
            });
        }

        res.json({ 
            is_defaulter: !!data.is_defaulter, 
            reason: data.defaulter_reason || "",
            has_admission_no: !!(data.admission_number && data.admission_number !== 'N/A')
        });
    } catch (err) {
        console.error("Router Crash:", err.message);
        res.status(500).json({ error: "Internal Server Error" });
    }
});

/**
 * POST /api/students/:id/mark-defaulter
 */
router.post('/:id/mark-defaulter', auth, setDefaulterStatus);

/**
 * POST /api/students/:id/remove-defaulter
 */
router.post('/:id/remove-defaulter', auth, (req, res, next) => {
    // Explicitly set the flag before passing to controller
    req.body.is_defaulter = false; 
    next();
}, setDefaulterStatus);

// --- Batch Routes ---
router.get('/:id/batches', auth, getStudentBatches);

module.exports = router;