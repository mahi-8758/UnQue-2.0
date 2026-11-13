import mongoose from "mongoose";

const appointmentSchema = new mongoose.Schema(
  {
    studentId: {
      type: mongoose.Schema.Types.ObjectId,
      ref: "User",
      required: true,
      index: true,
    },
    professorId: {
      type: mongoose.Schema.Types.ObjectId,
      ref: "User",
      required: true,
      index: true,
    },
    availabilityId: {
      type: mongoose.Schema.Types.ObjectId,
      ref: "Availability",
    },
    time: {
      type: Date,
      required: true,
    },
    status: {
      type: String,
      enum: ["booked", "completed", "cancelled"],
      default: "booked",
    },
  },
  { timestamps: true }
);

// Prevent duplicate active bookings for the same professor at the same time
appointmentSchema.index(
  { professorId: 1, time: 1 },
  { unique: true, partialFilterExpression: { status: "booked" } }
);

const Appointment = mongoose.model("Appointment", appointmentSchema);
export { Appointment };