import { HttpError } from "../models/error.js";
import { Availability } from "../models/availability.js";
import { Appointment } from "../models/appointment.js";
import moment from "moment";
import mongoose from "mongoose";

// Controller to set availability
const setAvailability = async (req, res, next) => {
  try {
    const { startTime, endTime } = req.body;

    if (!req.user || !req.user.id) {
      return next(new HttpError("No professor ID found", 400));
    }

    if (!startTime || !endTime) {
      return next(new HttpError("Start time and end time are required", 400));
    }

    const startDate = new Date(startTime);
    const endDate = new Date(endTime);

    if (isNaN(startDate.getTime()) || isNaN(endDate.getTime())) {
      return next(new HttpError("Invalid date format provided", 400));
    }

    // Ensure startTime is before endTime
    if (startDate >= endDate) {
      return next(new HttpError("Start time must be before end time", 400));
    }

    // Reject past timings
    if (startDate <= new Date()) {
      return next(new HttpError("Start time cannot be in the past", 400));
    }

    // Check for overlapping availability for this professor
    const existingAvailability = await Availability.findOne({
      professorId: req.user.id,
      status: { $ne: "cancelled" },
      startTime: { $lt: endDate },
      endTime: { $gt: startDate },
    });

    if (existingAvailability) {
      return next(new HttpError("This time slot overlaps with an existing availability slot", 400));
    }

    // Create new availability entry
    const availability = new Availability({
      professorId: req.user.id,
      startTime: startDate,
      endTime: endDate,
      status: "open",
      isBooked: false,
    });

    await availability.save();

    const formattedStartTime = moment.utc(availability.startTime).format("MMMM Do YYYY, h:mm:ss a");
    const formattedEndTime = moment.utc(availability.endTime).format("MMMM Do YYYY, h:mm:ss a");

    res.status(201).json({
      message: "Availability added successfully",
      availability: {
        _id: availability._id,
        professorId: availability.professorId,
        startTime: formattedStartTime,
        endTime: formattedEndTime,
        rawStartTime: availability.startTime,
        rawEndTime: availability.endTime,
        status: availability.status,
        isBooked: availability.isBooked,
      },
    });
  } catch (error) {
    return next(new HttpError(error.message || "Adding availability failed", 500));
  }
};

// NEW API: Update an existing free availability slot without deleting its database record
const updateAvailabilitySlot = async (req, res, next) => {
  try {
    const { slotId } = req.params;
    const { startTime, endTime } = req.body;
    const professorId = req.user.id;

    if (!slotId || !mongoose.Types.ObjectId.isValid(slotId)) {
      return next(new HttpError("Invalid availability slot ID format", 400));
    }

    if (!startTime || !endTime) {
      return next(new HttpError("Start time and end time are required", 400));
    }

    const newStart = new Date(startTime);
    const newEnd = new Date(endTime);

    if (isNaN(newStart.getTime()) || isNaN(newEnd.getTime())) {
      return next(new HttpError("Invalid date format provided", 400));
    }

    if (newStart >= newEnd) {
      return next(new HttpError("Start time must be before end time", 400));
    }

    if (newStart <= new Date()) {
      return next(new HttpError("Start time cannot be in the past", 400));
    }

    // Find the slot
    const slot = await Availability.findById(slotId);
    if (!slot) {
      return next(new HttpError("Availability slot not found", 404));
    }

    // Verify slot belongs to logged-in professor
    if (slot.professorId.toString() !== professorId) {
      return next(new HttpError("Access denied, you can only update your own availability slots", 403));
    }

    // Verify slot is free
    if (slot.isBooked || slot.status === "booked") {
      return next(new HttpError("Cannot update a booked availability slot", 400));
    }

    // Cross-check that no active appointment is booked on this slot
    const activeAppointment = await Appointment.findOne({
      availabilityId: slot._id,
      status: "booked",
    });
    if (activeAppointment) {
      return next(new HttpError("Cannot update slot: an active appointment exists for this slot", 400));
    }

    // Prevent overlap with OTHER availability slots belonging to this professor
    const overlappingSlot = await Availability.findOne({
      professorId,
      _id: { $ne: slot._id },
      status: { $ne: "cancelled" },
      startTime: { $lt: newEnd },
      endTime: { $gt: newStart },
    });
    if (overlappingSlot) {
      return next(new HttpError("Updated slot overlaps with another existing availability slot", 400));
    }

    // Prevent conflicts with existing booked appointments of this professor
    const conflictingAppt = await Appointment.findOne({
      professorId,
      status: "booked",
      time: { $gte: newStart, $lte: newEnd },
    });
    if (conflictingAppt) {
      return next(new HttpError("Updated slot conflicts with an existing booked appointment", 400));
    }

    // Update in-place: preserves the original MongoDB _id
    slot.startTime = newStart;
    slot.endTime = newEnd;
    await slot.save();

    res.status(200).json({
      message: "Availability slot updated successfully",
      availability: {
        _id: slot._id,
        professorId: slot.professorId,
        startTime: slot.startTime,
        endTime: slot.endTime,
        formattedStartTime: moment.utc(slot.startTime).format("MMMM Do YYYY, h:mm:ss a"),
        formattedEndTime: moment.utc(slot.endTime).format("MMMM Do YYYY, h:mm:ss a"),
        status: slot.status,
        isBooked: slot.isBooked,
      },
    });
  } catch (error) {
    return next(new HttpError(error.message || "Failed to update availability slot", 500));
  }
};

// API to list all appointments for the authenticated professor
const getProfessorAppointments = async (req, res, next) => {
  try {
    const professorId = req.user.id;

    const appointments = await Appointment.find({
      professorId: new mongoose.Types.ObjectId(professorId),
    })
      .populate("studentId", "name email")
      .sort({ time: 1 });

    const formattedAppointments = appointments.map((appointment) => ({
      _id: appointment._id,
      studentId: appointment.studentId?._id || appointment.studentId,
      studentName: appointment.studentId?.name || "Unknown Student",
      studentEmail: appointment.studentId?.email || "Unknown Email",
      time: appointment.time,
      formattedTime: moment.utc(appointment.time).format("MMMM Do YYYY, h:mm:ss a"),
      status: appointment.status,
      availabilityId: appointment.availabilityId,
    }));

    res.status(200).json({
      message: "Professor appointments retrieved successfully",
      appointments: formattedAppointments,
    });
  } catch (error) {
    return next(new HttpError(error.message || "Failed to retrieve appointments", 500));
  }
};

// API to cancel a specific appointment by appointment ID
const cancelAppointmentById = async (req, res, next) => {
  try {
    const { appointmentId } = req.params;
    const professorId = req.user.id;

    if (!appointmentId || !mongoose.Types.ObjectId.isValid(appointmentId)) {
      return next(new HttpError("Invalid appointment ID format", 400));
    }

    const appointment = await Appointment.findById(appointmentId);
    if (!appointment) {
      return next(new HttpError("Appointment not found", 404));
    }

    if (appointment.professorId.toString() !== professorId) {
      return next(new HttpError("Access denied, you can only cancel appointments booked with you", 403));
    }

    if (appointment.status === "cancelled") {
      return next(new HttpError("Appointment is already cancelled", 400));
    }

    appointment.status = "cancelled";
    await appointment.save();

    // Free up the corresponding availability slot
    if (appointment.availabilityId) {
      await Availability.findByIdAndUpdate(appointment.availabilityId, {
        isBooked: false,
        status: "open",
      });
    } else {
      // Fallback: look up slot covering appointment time
      await Availability.findOneAndUpdate(
        {
          professorId,
          startTime: { $lte: appointment.time },
          endTime: { $gte: appointment.time },
        },
        { isBooked: false, status: "open" }
      );
    }

    res.status(200).json({
      message: "Appointment cancelled successfully",
      appointment: {
        _id: appointment._id,
        professorId: appointment.professorId,
        studentId: appointment.studentId,
        time: appointment.time,
        status: appointment.status,
      },
    });
  } catch (error) {
    return next(new HttpError(error.message || "Error cancelling appointment", 500));
  }
};

// Existing cancel appointments by studentId (improved and fixed)
const cancelAppointments = async (req, res, next) => {
  try {
    const { studentId } = req.params;
    const professorId = req.user.id;

    if (!studentId || !mongoose.Types.ObjectId.isValid(studentId)) {
      return next(new HttpError("Invalid or missing student ID", 400));
    }

    // Finding booked appointments between this professor and student
    const appointments = await Appointment.find({
      studentId: new mongoose.Types.ObjectId(studentId),
      professorId: new mongoose.Types.ObjectId(professorId),
      status: "booked",
    });

    if (!appointments || appointments.length === 0) {
      return next(new HttpError("No active appointments found to cancel for this student", 404));
    }

    // Free up availability slots for these appointments
    const availabilityIds = appointments
      .map((a) => a.availabilityId)
      .filter((id) => id);

    if (availabilityIds.length > 0) {
      await Availability.updateMany(
        { _id: { $in: availabilityIds } },
        { isBooked: false, status: "open" }
      );
    }

    // Update status to 'cancelled' (consistent spelling)
    await Appointment.updateMany(
      {
        studentId: new mongoose.Types.ObjectId(studentId),
        professorId: new mongoose.Types.ObjectId(professorId),
        status: "booked",
      },
      { status: "cancelled" }
    );

    res.status(200).json({
      message: `All appointments between professor ${professorId} and student ${studentId} have been cancelled.`,
    });
  } catch (error) {
    return next(new HttpError(error.message || "Error cancelling appointments", 500));
  }
};

export {
  setAvailability,
  updateAvailabilitySlot,
  getProfessorAppointments,
  cancelAppointmentById,
  cancelAppointments,
};