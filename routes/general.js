import { authMiddleware, studentMiddleware } from "../middleware/auth.js";
import express from "express";
import {
  getAvailableSlots,
  bookAppointment,
  getStudentAppointments,
} from "../controllers/general.js";

const router = express.Router();

// Route to get available slots for a professor
router.get("/professor/:professorId/availability", authMiddleware, getAvailableSlots);

// Route to book an appointment (student only)
router.post("/book", authMiddleware, studentMiddleware, bookAppointment);

// Route to view student's appointments (student only)
router.get("/appointments", authMiddleware, studentMiddleware, getStudentAppointments);

export default router;