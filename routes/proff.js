import express from "express";
import {
  setAvailability,
  updateAvailabilitySlot,
  getProfessorAppointments,
  cancelAppointmentById,
  cancelAppointments,
} from "../controllers/proff.js";
import { authMiddleware, profMiddleware } from "../middleware/auth.js";

const router = express.Router();

// Route to add availability
router.post("/availability", authMiddleware, profMiddleware, setAvailability);

// Route to update an existing free availability slot (NEW API)
router.patch("/availability/:slotId", authMiddleware, profMiddleware, updateAvailabilitySlot);

// Route to list all appointments for the authenticated professor
router.get("/appointments", authMiddleware, profMiddleware, getProfessorAppointments);

// Route to cancel a specific appointment by appointment ID
router.patch("/cancel-appointment/:appointmentId", authMiddleware, profMiddleware, cancelAppointmentById);

// Route to cancel appointments between professor and student (backward compatible)
router.patch("/cancel-appointments/:studentId", authMiddleware, profMiddleware, cancelAppointments);

export default router;
