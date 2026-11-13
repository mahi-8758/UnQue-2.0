import mongoose from "mongoose";

const availabilitySchema = new mongoose.Schema(
  {
    professorId: {
      type: mongoose.Schema.Types.ObjectId,
      ref: "User",
      required: true,
      index: true,
    },
    startTime: {
      type: Date,
      required: true,
    },
    endTime: {
      type: Date,
      required: true,
    },
    status: {
      type: String,
      enum: ["open", "booked", "cancelled"],
      default: "open",
    },
    isBooked: {
      type: Boolean,
      default: false,
    },
  },
  { timestamps: true }
);

availabilitySchema.index({ professorId: 1, startTime: 1, endTime: 1 });

const Availability = mongoose.model("Availability", availabilitySchema);
export { Availability };
