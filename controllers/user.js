import { HttpError } from "../models/error.js";
import { User } from "../models/user.js";
import bcrypt from "bcryptjs";
import jwt from "jsonwebtoken";
import mongoose from "mongoose";

// User Registration Controller
const register = async (req, res, next) => {
  try {
    const { name, email, password, confirmPassword, role } = req.body;
    if (!name || !email || !password || !role) {
      return next(new HttpError("Fill in all the fields", 422));
    }

    if (role !== "professor" && role !== "student") {
      return next(new HttpError("Role must be either professor or student", 422));
    }

    const newEmail = email.toLowerCase().trim();
    const emailExists = await User.findOne({ email: newEmail });
    if (emailExists) {
      return next(new HttpError("Email already exists.", 422));
    }
    if (password.trim().length < 4) {
      return next(new HttpError("Password must be at least 4 characters long", 422));
    }
    if (password !== confirmPassword) {
      return next(new HttpError("Passwords do not match", 422));
    }

    const salt = await bcrypt.genSalt(11);
    const hashedPassword = await bcrypt.hash(password, salt);
    const newUser = await User.create({
      name: name.trim(),
      email: newEmail,
      password: hashedPassword,
      role,
    });

    res.status(201).json({
      message: "User registered successfully",
      user: {
        id: newUser._id,
        name: newUser.name,
        email: newUser.email,
        role: newUser.role,
      },
    });
  } catch (error) {
    return next(new HttpError(error.message || "User Registration Failed", 422));
  }
};

const login = async (req, res, next) => {
  try {
    const { email, password } = req.body;
    if (!email || !password) {
      return next(new HttpError("Fill in all fields", 400));
    }
    const newEmail = email.toLowerCase().trim();
    const user = await User.findOne({ email: newEmail });
    if (!user) {
      return next(new HttpError("Invalid credentials", 401));
    }
    const comparePassword = await bcrypt.compare(password, user.password);
    if (!comparePassword) {
      return next(new HttpError("Invalid credentials", 401));
    }
    const { _id: id, name, role } = user;
    const token = jwt.sign({ id, name, role }, process.env.JWT_SECRET, {
      expiresIn: "2d",
    });
    res.status(200).json({ token, id, name, role });
  } catch (error) {
    return next(new HttpError(error.message || "Login failed", 500));
  }
};

const getUserProfile = async (req, res, next) => {
  try {
    const { id } = req.params;

    if (!mongoose.Types.ObjectId.isValid(id)) {
      return next(new HttpError("Invalid user ID format", 400));
    }

    // Prevent unauthorized users from accessing other users' private information
    if (!req.user || req.user.id !== id) {
      return next(new HttpError("Access denied. You can only view your own profile.", 403));
    }

    const user = await User.findById(id).select("-password");
    if (!user) {
      return next(new HttpError("User not found", 404));
    }
    res.status(200).json(user);
  } catch (error) {
    return next(new HttpError(error.message || "Failed to retrieve user profile", 500));
  }
};

export { register, login, getUserProfile };  
