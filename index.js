import express from "express";
import mongoose from "mongoose";
import cors from "cors";
import dotenv from "dotenv";
import helmet from "helmet";
import morgan from "morgan";
import { notFound, errorMiddleware } from "./middleware/error.js";

import userRoutes from "./routes/user.js";
import professorRoutes from "./routes/proff.js";
import generalRoutes from "./routes/general.js";

import { fileURLToPath } from "url";
import path from "path";

dotenv.config();
const app = express();

// Body parsing middleware
app.use(express.json());
app.use(express.urlencoded({ extended: false }));

// Security & logging middleware
app.use(helmet());
app.use(helmet.crossOriginResourcePolicy({ policy: "cross-origin" }));
app.use(morgan("common"));
app.use(cors());

// Application routes
app.use("/users", userRoutes);
app.use("/professor", professorRoutes);
app.use("/general", generalRoutes);

// Error-handling middleware
app.use(notFound);
app.use(errorMiddleware);

const PORT = process.env.PORT || 5001;

const startServer = async () => {
  try {
    if (!process.env.MONGO_URL) {
      throw new Error("MONGO_URL environment variable is not defined.");
    }
    await mongoose.connect(process.env.MONGO_URL);
    console.log("Database connected successfully.");
    app.listen(PORT, () => console.log(`Server running on Port: ${PORT}`));
  } catch (error) {
    console.error(`Database connection failed: ${error.message}`);
    process.exit(1);
  }
};

// Check if this module is the main process entrypoint
const isRunDirectly = () => {
  if (!process.argv[1]) return false;
  try {
    return path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url));
  } catch {
    return false;
  }
};

if (isRunDirectly() && process.env.NODE_ENV !== "test") {
  startServer();
}

export default app;
export { app, startServer }; 

