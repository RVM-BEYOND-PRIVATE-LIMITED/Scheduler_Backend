const supabase = require('../db.js');

/**
 * @description 
 * Fetches all payment records with a total collection sum for auditing.
 * Super Admins see all branches; standard Admins are restricted by location.
 * [UPDATED] Added student_phone_number to search logic.
 */
exports.getPaymentLedger = async (req, res) => {
  // Increased default limit to 1000 to handle higher volume audit periods
  const { from, to, location, method, searchTerm, page = 1, limit = 10000 } = req.query;
  const locationId = req.locationId;
  const isSuperAdmin = req.isSuperAdmin; 

  try {
    // 1. Base Query Setup - Selecting from the location-aware view
    let query = supabase
      .from("v_payments_with_location")
      .select("*", { count: "exact" });

    // 2. Apply Filters (Shared by both data and total sum)
    if (!isSuperAdmin) {
      // ✅ Staff-level security: Restricted to their assigned branch
      if (!locationId) return res.status(403).json({ error: "No branch context." });
      query = query.eq('location_id', locationId);
    } else if (location && location !== 'all') {
      // ✅ Super Admin filter by specific branch name (if provided)
      query = query.eq('location_name', location);
    }

    if (from) query = query.gte("payment_date", from);
    if (to) query = query.lte("payment_date", to);
    if (method && method !== 'all') query = query.eq("method", method);

    if (searchTerm) {
      // ✅ UPDATED: Added student_phone_number to the search parameters
      query = query.or(`student_name.ilike.%${searchTerm}%,receipt_number.ilike.%${searchTerm}%,admission_number.ilike.%${searchTerm}%,student_phone_number.ilike.%${searchTerm}%`);
    }

    // 3. FETCH DATA (Paginated)
    const parsedPage = Math.max(1, Number(page));
    const parsedLimit = Math.max(1, Number(limit));
    const start = (parsedPage - 1) * parsedLimit;
    const end = start + parsedLimit - 1;
    
    const { data: payments, count, error: dataError } = await query
      .order("payment_date", { ascending: false })
      .order("receipt_number", { ascending: false })
      .range(start, end);

    if (dataError) throw dataError;

    // 4. CALCULATE TOTAL COLLECTION
    // Re-use filtered query logic for a lightweight total aggregation
    const { data: totalsData, error: totalError } = await query.select('amount_paid');
    
    if (totalError) throw totalError;

    const totalAmount = (totalsData || []).reduce((sum, p) => sum + Number(p.amount_paid), 0);

    // 5. Response
    res.status(200).json({
      payments: payments || [],
      total: count,
      page: parsedPage,
      limit: parsedLimit,
      meta: {
        totalAmount: totalAmount, // For 'Total Collection' Card
        totalRecords: count       // For 'Receipts Generated' Card
      }
    });

  } catch (error) {
    console.error("Ledger Error:", error);
    res.status(500).json({ error: "Internal Server Error" });
  }
};