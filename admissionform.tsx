import { useState, useMemo } from "react";
import { Plus, Trash2, IndianRupee, Percent, CheckCircle } from "lucide-react"; // Removed Clock
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Label } from "@/components/ui/label";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Textarea } from "@/components/ui/textarea";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { Checkbox } from "@/components/ui/checkbox";
// NOTE: Assuming DatePicker is a component that handles date selection and returns a string or Date object
// import { DatePicker } from "@/components/ui/date-picker"; 
import { AdmissionFormData, Certificate, Course, Installment } from "@/types/admissionManagement";
import { format, parseISO } from 'date-fns';

// --- Mock Components for UI clarity (Replace with your actual components) ---
const DatePicker = ({ selected, onSelect, placeholder }) => (
  <Input 
    type="date" 
    value={selected || ""} 
    onChange={(e) => onSelect(e.target.value)} 
    placeholder={placeholder} 
  />
);

// --- Mock Data ---
const AVAILABLE_CERTIFICATES: Certificate[] = [
  { id: "cert1", name: "Certificate of Completion", price: 500 },
  { id: "cert2", name: "Advanced Certificate", price: 1000 },
];

const AVAILABLE_COURSES: Course[] = Array.from({ length: 30 }, (_, i) => ({
  id: `course${i + 1}`,
  name: `Course ${i + 1}`,
  price: 1500 + i * 100,
}));

export default function AdmissionForm() {
  const [formData, setFormData] = useState<AdmissionFormData>({
    name: "",
    phone_number: "",
    father_name: "",
    father_phone_number: "",
    permanent_address: "",
    current_address: "",
    id_card_type: "Aadhar Card",
    id_card_number: "",
    course_joining_date: "",
    batch_preference: "",
    selected_certificates: [],
    selected_courses: [],
    discount_percentage: 0,
    total_fees: 0,
    final_fees: 0,
    installments: [],
  });

  const [newInstallment, setNewInstallment] = useState<Omit<Installment, 'id' | 'status'>>({ due_date: "", amount: 0 });

  // --- Fee Calculation Logic (Simplified without GST) ---
  const { totalFees, finalFees } = useMemo(() => {
    const certificateFees = formData.selected_certificates.reduce((acc, cert) => acc + cert.price, 0);
    const courseFees = formData.selected_courses.reduce((acc, course) => acc + course.price, 0);
    const calculatedTotalFees = certificateFees + courseFees;
    
    const discountAmount = (calculatedTotalFees * formData.discount_percentage) / 100;
    const calculatedFinalFees = calculatedTotalFees - discountAmount;
    
    return {
      totalFees: calculatedTotalFees,
      finalFees: calculatedFinalFees,
    };
  }, [formData.selected_certificates, formData.selected_courses, formData.discount_percentage]);

  const handleInputChange = (e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement>) => {
    const { id, value } = e.target;
    setFormData({ ...formData, [id]: value });
  };

  const handleSelectChange = (id: string, value: string) => {
    setFormData({ ...formData, [id]: value });
  };

  const handleDiscountChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const discount = parseFloat(e.target.value);
    setFormData({ ...formData, discount_percentage: isNaN(discount) ? 0 : discount });
  };
  
  const handleCertificateChange = (certificate: Certificate) => {
    setFormData((prev) => {
      const isSelected = prev.selected_certificates.some((c) => c.id === certificate.id);
      const selected_certificates = isSelected
        ? prev.selected_certificates.filter((c) => c.id !== certificate.id)
        : [...prev.selected_certificates, certificate];
      return { ...prev, selected_certificates };
    });
  };

  const handleCourseChange = (course: Course) => {
    setFormData((prev) => {
      const isSelected = prev.selected_courses.some((c) => c.id === course.id);
      const selected_courses = isSelected
        ? prev.selected_courses.filter((c) => c.id !== course.id)
        : [...prev.selected_courses, course];
      return { ...prev, selected_courses };
    });
  };

  const addInstallment = () => {
    if (newInstallment.due_date && newInstallment.amount > 0) {
      setFormData({
        ...formData,
        installments: [
          ...formData.installments,
          { ...newInstallment, id: `inst-${Date.now()}`, status: "Pending" },
        ],
      });
      setNewInstallment({ due_date: "", amount: 0 });
    }
  };

  const removeInstallment = (id: string) => {
    setFormData({
      ...formData,
      installments: formData.installments.filter((inst) => inst.id !== id),
    });
  };

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    // Final data structure passed to backend
    const submissionData = {
        ...formData, 
        total_fees: totalFees, 
        final_fees: finalFees,
    };
    console.log("Admission form submitted:", submissionData);
    alert("Admission form submitted! Check the console for the final structured data.");
  };

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-3xl font-bold tracking-tight">New Student Admission</h1>
          <p className="text-muted-foreground">Fill out the form to enroll a new student and set the financial plan.</p>
        </div>
        <Button type="submit" onClick={handleSubmit}>
          <CheckCircle className="h-4 w-4 mr-2" /> Save Full Admission
        </Button>
      </div>
      
      <form onSubmit={handleSubmit} className="space-y-6">
        <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
          
          {/* --- LEFT COLUMN: Student & Course Details --- */}
          <div className="lg:col-span-2 space-y-6">
            
            {/* Student Information */}
            <Card>
              <CardHeader>
                <CardTitle>Student Information</CardTitle>
              </CardHeader>
              <CardContent className="grid grid-cols-1 md:grid-cols-2 gap-4">
                <div className="space-y-2">
                  <Label htmlFor="name">Student Name</Label>
                  <Input id="name" value={formData.name} onChange={handleInputChange} required />
                </div>
                <div className="space-y-2">
                  <Label htmlFor="phone_number">Phone Number</Label>
                  <Input id="phone_number" type="tel" value={formData.phone_number} onChange={handleInputChange} required />
                </div>
                <div className="space-y-2">
                  <Label htmlFor="father_name">Father's Name</Label>
                  <Input id="father_name" value={formData.father_name} onChange={handleInputChange} required />
                </div>
                <div className="space-y-2">
                  <Label htmlFor="father_phone_number">Father's Phone Number</Label>
                  <Input id="father_phone_number" type="tel" value={formData.father_phone_number} onChange={handleInputChange} />
                </div>
                <div className="space-y-2 md:col-span-2">
                  <Label htmlFor="permanent_address">Permanent Address</Label>
                  <Textarea id="permanent_address" value={formData.permanent_address} onChange={handleInputChange} required />
                </div>
                <div className="space-y-2 md:col-span-2">
                  <Label htmlFor="current_address">Current Address</Label>
                  <Textarea id="current_address" value={formData.current_address} onChange={handleInputChange} />
                </div>
                <div className="space-y-2">
                  <Label htmlFor="id_card_type">ID Card Type</Label>
                  <Select value={formData.id_card_type} onValueChange={(value) => handleSelectChange("id_card_type", value)}>
                      <SelectTrigger id="id_card_type">
                          <SelectValue placeholder="Select ID Card Type" />
                      </SelectTrigger>
                      <SelectContent>
                          <SelectItem value="Aadhar Card">Aadhar Card</SelectItem>
                          <SelectItem value="Passport">Passport</SelectItem>
                          <SelectItem value="Other">Other</SelectItem>
                      </SelectContent>
                  </Select>
                </div>
                <div className="space-y-2">
                  <Label htmlFor="id_card_number">ID Card Number</Label>
                  <Input id="id_card_number" value={formData.id_card_number} onChange={handleInputChange} required />
                </div>
                <div className="space-y-2">
                  <Label htmlFor="course_joining_date">Course Joining Date</Label>
                  <DatePicker
                    selected={formData.course_joining_date}
                    onSelect={(date) => handleSelectChange("course_joining_date", date)}
                    placeholder="Select joining date"
                  />
                </div>
                <div className="space-y-2">
                  <Label htmlFor="batch_preference">Batch Preference</Label>
                  <Select value={formData.batch_preference} onValueChange={(value) => handleSelectChange("batch_preference", value)}>
                      <SelectTrigger id="batch_preference">
                          <SelectValue placeholder="Select Batch Preference" />
                      </SelectTrigger>
                      <SelectContent>
                          <SelectItem value="Morning">Morning</SelectItem>
                          <SelectItem value="Afternoon">Afternoon</SelectItem>
                          <SelectItem value="Evening">Evening</SelectItem>
                      </SelectContent>
                  </Select>
                </div>
              </CardContent>
            </Card>

            {/* Course and Certificate Selection */}
            <Card>
              <CardHeader>
                <CardTitle>Course and Certificate Selection</CardTitle>
                <CardDescription>Select all courses and certifications for enrollment.</CardDescription>
              </CardHeader>
              <CardContent className="grid md:grid-cols-2 gap-6">
                <div>
                  <Label className="mb-2 block font-semibold">Certifications</Label>
                  <div className="space-y-2">
                    {AVAILABLE_CERTIFICATES.map((cert) => (
                      <div key={cert.id} className="flex items-center space-x-2">
                        <Checkbox
                          id={`cert-${cert.id}`}
                          checked={formData.selected_certificates.some((c) => c.id === cert.id)}
                          onCheckedChange={() => handleCertificateChange(cert)}
                        />
                        <label htmlFor={`cert-${cert.id}`} className="text-sm font-medium leading-none">
                          {cert.name} (<IndianRupee className="inline h-3 w-3 align-text-bottom" />{cert.price})
                        </label>
                      </div>
                    ))}
                  </div>
                </div>
                
                <div>
                  <Label className="mb-2 block font-semibold">Courses</Label>
                  <div className="h-64 overflow-y-auto border rounded-md p-2">
                    {AVAILABLE_COURSES.map((course) => (
                      <div key={course.id} className="flex items-center space-x-2 p-1 border-b last:border-b-0">
                        <Checkbox
                          id={`course-${course.id}`}
                          checked={formData.selected_courses.some((c) => c.id === course.id)}
                          onCheckedChange={() => handleCourseChange(course)}
                        />
                        <label htmlFor={`course-${course.id}`} className="text-sm font-medium leading-none">
                          {course.name} (<IndianRupee className="inline h-3 w-3 align-text-bottom" />{course.price})
                        </label>
                      </div>
                    ))}
                  </div>
                </div>
              </CardContent>
            </Card>
          </div>

          {/* --- RIGHT COLUMN: Fee Details & Installments --- */}
          <div className="space-y-6">
            
            {/* Fee Details */}
            <Card>
              <CardHeader>
                <CardTitle>Fee Summary</CardTitle>
              </CardHeader>
              <CardContent className="space-y-4">
                
                {/* Initial Fees and Discount */}
                <div className="space-y-2 border-b pb-3">
                  <div className="flex justify-between items-center text-sm text-muted-foreground">
                    <span>Base Course Fees</span>
                    <span className="font-semibold">₹{totalFees.toFixed(2)}</span>
                  </div>
                  <div className="space-y-2">
                    <Label htmlFor="discount_percentage">Discount (<Percent className="inline h-3 w-3" />)</Label>
                    <Input
                      id="discount_percentage"
                      type="number"
                      value={formData.discount_percentage}
                      onChange={handleDiscountChange}
                      min="0"
                      max="100"
                    />
                  </div>
                  <div className="flex justify-between items-center font-medium text-base pt-2">
                    <span>Total Amount</span>
                    <span className="font-bold text-lg text-blue-600">₹{finalFees.toFixed(2)}</span>
                  </div>
                </div>
                
                {/* Final Payable Amount */}
                <div className="pt-4 border-t-2 border-primary/20">
                  <div className="flex justify-between items-center font-extrabold text-xl text-primary">
                    <span>Total Payable</span>
                    <span>₹{finalFees.toFixed(2)}</span>
                  </div>
                </div>
              </CardContent>
            </Card>

            {/* Installment Plan */}
            <Card>
              <CardHeader>
                <CardTitle className="text-lg flex items-center"><IndianRupee className="h-4 w-4 mr-2"/> Installment Plan</CardTitle>
                <CardDescription>Total payable: ₹{finalFees.toFixed(2)}</CardDescription>
              </CardHeader>
              <CardContent className="space-y-4">
                <div className="grid grid-cols-2 gap-4 items-end">
                  <div className="space-y-2">
                    <Label>Due Date</Label>
                    <DatePicker
                      selected={newInstallment.due_date}
                      onSelect={(date) => setNewInstallment({ ...newInstallment, due_date: date })}
                      placeholder="Select date"
                    />
                  </div>
                  <div className="space-y-2">
                    <Label>Amount (₹)</Label>
                    <Input
                      type="number"
                      value={newInstallment.amount || ''}
                      onChange={(e) => setNewInstallment({ ...newInstallment, amount: parseFloat(e.target.value) || 0 })}
                      min="1"
                    />
                  </div>
                </div>
                <Button type="button" onClick={addInstallment} className="w-full">
                  <Plus className="h-4 w-4 mr-2" /> Add Installment
                </Button>
                
                <Table className="mt-4">
                  <TableHeader>
                    <TableRow className="bg-gray-50">
                      <TableHead>Due Date</TableHead>
                      <TableHead>Amount</TableHead>
                      <TableHead className="text-right">Actions</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {formData.installments.map((inst) => (
                      <TableRow key={inst.id}>
                        <TableCell className="font-medium">{inst.due_date ? format(parseISO(inst.due_date), 'MMM d, yyyy') : ''}</TableCell>
                        <TableCell>₹{inst.amount.toFixed(2)}</TableCell>
                        <TableCell className="text-right">
                          <Button variant="ghost" size="icon" onClick={() => removeInstallment(inst.id)}>
                            <Trash2 className="h-4 w-4 text-red-500" />
                          </Button>
                        </TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
              </CardContent>
            </Card>

          </div>
        </div>
      </form>
    </div>
  );
}


