import { Availability } from "../models/availability.js";
import { HttpError } from "../models/error.js";
import { Appointment } from "../models/appointment.js";
import mongoose from "mongoose";
import moment from "moment";

const getAvailableSlots = async (req, res, next) => {
  try {
    const { professorId } = req.params;

    // Check if professorId is valid
    if (!professorId || !mongoose.Types.ObjectId.isValid(professorId)) {
      return next(new HttpError("Invalid professor ID format", 400));
    }

    // Find open, unbooked availability slots for the professor that haven't ended yet
    const availability = await Availability.find({
      professorId: new mongoose.Types.ObjectId(professorId),
      status: "open",
      isBooked: false,
      endTime: { $gt: new Date() },
    }).sort({ startTime: 1 });

    // Format the available slots with IDs and standardized dates
    const availableSlots = availability.map((avail) => ({
      _id: avail._id,
      professorId: avail.professorId,
      startTime: moment.utc(avail.startTime).format("MMMM Do YYYY, h:mm:ss a"),
      endTime: moment.utc(avail.endTime).format("MMMM Do YYYY, h:mm:ss a"),
      rawStartTime: avail.startTime,
      rawEndTime: avail.endTime,
      status: avail.status,
      isBooked: avail.isBooked,
    }));

    res.status(200).json({ availableSlots });
  } catch (error) {
    return next(new HttpError(error.message || "Failed to fetch availability", 500));
  }
};

const bookAppointment = async (req, res, next) => {
  try {
    const { professorId, time } = req.body;
    const studentId = req.user.id;

    if (!professorId || !time) {
      return next(new HttpError("Professor ID and time are required", 400));
    }

    if (!mongoose.Types.ObjectId.isValid(professorId)) {
      return next(new HttpError("Invalid professor ID format", 400));
    }

    const bookingDate = new Date(time);
    if (isNaN(bookingDate.getTime())) {
      return next(new HttpError("Invalid date/time format provided", 400));
    }

    // Reject past appointment timings
    if (bookingDate <= new Date()) {
      return next(new HttpError("Cannot book appointments in the past", 400));
    }

    const formattedTime = moment(time).utc().toDate();

    // Check if this student already has an active booking at this time
    const existingStudentBooking = await Appointment.findOne({
      studentId: new mongoose.Types.ObjectId(studentId),
      time: formattedTime,
      status: "booked",
    });

    if (existingStudentBooking) {
      return next(new HttpError("You already have an appointment booked for this time", 400));
    }

    // 1. Atomically claim the availability slot only if status is "open" and isBooked is false
    const availability = await Availability.findOneAndUpdate(
      {
        professorId: new mongoose.Types.ObjectId(professorId),
        startTime: { $lte: formattedTime },
        endTime: { $gt: formattedTime },
        status: "open",
        isBooked: false,
      },
      {
        $set: {
          status: "booked",
          isBooked: true,
        },
      },
      { new: true }
    );

    // If atomic update failed, determine whether the slot never existed or is already booked
    if (!availability) {
      const slotExists = await Availability.findOne({
        professorId: new mongoose.Types.ObjectId(professorId),
        startTime: { $lte: formattedTime },
        endTime: { $gt: formattedTime },
      });

      if (!slotExists) {
        return next(new HttpError("Selected time is not available for booking", 400));
      }

      return next(new HttpError("This time slot is already booked for this professor", 409));
    }

    // 2. Attempt to create and save the Appointment
    let appointment;
    try {
      appointment = new Appointment({
        studentId: new mongoose.Types.ObjectId(studentId),
        professorId: new mongoose.Types.ObjectId(professorId),
        availabilityId: availability._id,
        time: formattedTime,
        status: "booked",
      });

      await appointment.save();
    } catch (apptError) {
      // 3. Rollback: If appointment creation fails, safely restore availability slot to open state
      await Availability.findByIdAndUpdate(availability._id, {
        $set: {
          status: "open",
          isBooked: false,
        },
      });

      if (apptError.code === 11000) {
        return next(new HttpError("This time slot has already been booked", 409));
      }
      return next(new HttpError(apptError.message || "Failed to book appointment", 500));
    }

    const formattedAppointmentTime = moment.utc(appointment.time).format("MMMM Do YYYY, h:mm:ss a");

    res.status(201).json({
      message: "Appointment booked successfully",
      appointment: {
        _id: appointment._id,
        studentId: appointment.studentId,
        professorId: appointment.professorId,
        availabilityId: availability._id,
        time: formattedAppointmentTime,
        rawTime: appointment.time,
        status: appointment.status,
      },
    });
  } catch (error) {
    return next(new HttpError(error.message || "Failed to book appointment", 500));
  }
};

const getStudentAppointments = async (req, res, next) => {
  try {
    const studentId = req.user.id;

    // Fetch all booked appointments for the student
    const appointments = await Appointment.find({
      studentId: new mongoose.Types.ObjectId(studentId),
      status: "booked",
    })
      .populate("professorId", "name email")
      .sort({ time: 1 });

    // Return HTTP 200 with an empty array when a student has no appointments
    if (!appointments || appointments.length === 0) {
      return res.status(200).json({
        message: "Your upcoming appointments:",
        appointments: [],
      });
    }

    // Format the response safely handling null populated references
    const formattedAppointments = appointments.map((appointment) => ({
      _id: appointment._id,
      professor: appointment.professorId?.name || "Unknown Professor",
      professorEmail: appointment.professorId?.email || "Unknown Email",
      professorId: appointment.professorId?._id || appointment.professorId,
      appointmentTime: moment.utc(appointment.time).format("MMMM Do YYYY, h:mm:ss a"),
      time: appointment.time,
      status: appointment.status,
      availabilityId: appointment.availabilityId,
    }));

    res.status(200).json({
      message: "Your upcoming appointments:",
      appointments: formattedAppointments,
    });
  } catch (error) {
    return next(new HttpError(error.message || "Failed to retrieve appointments", 500));
  }
};

export { getAvailableSlots, bookAppointment, getStudentAppointments };