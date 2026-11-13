process.env.NODE_ENV = "test";
process.env.JWT_SECRET = "test_jwt_secret_key_12345";

import mongoose from "mongoose";
import { MongoMemoryServer } from "mongodb-memory-server";
import http from "http";
import { Appointment } from "../models/appointment.js";
import { Availability } from "../models/availability.js";

let mongod;
let server;
let baseUrl;
let app;

const makeRequest = async (path, method = "GET", body = null, token = null) => {
  const url = new URL(path, baseUrl);
  const headers = { "Content-Type": "application/json" };
  if (token) {
    headers["Authorization"] = `Bearer ${token}`;
  }

  const options = {
    method,
    headers,
  };

  return new Promise((resolve, reject) => {
    const req = http.request(url, options, (res) => {
      let data = "";
      res.on("data", (chunk) => (data += chunk));
      res.on("end", () => {
        let json;
        try {
          json = JSON.parse(data);
        } catch {
          json = data;
        }
        resolve({ status: res.statusCode, data: json });
      });
    });

    req.on("error", reject);

    if (body) {
      req.write(JSON.stringify(body));
    }
    req.end();
  });
};

const runTests = async () => {
  console.log("Starting in-memory MongoDB server...");
  mongod = await MongoMemoryServer.create();
  const uri = mongod.getUri();
  process.env.MONGO_URL = uri;
  process.env.JWT_SECRET = "test_jwt_secret_key_12345";
  process.env.NODE_ENV = "test";

  await mongoose.connect(uri);
  console.log("Connected to in-memory database.");

  app = (await import("../index.js")).default;

  // Start HTTP server on an ephemeral port
  server = http.createServer(app);
  await new Promise((resolve) => server.listen(0, resolve));
  const port = server.address().port;
  baseUrl = `http://127.0.0.1:${port}`;
  console.log(`Test server running at ${baseUrl}\n`);

  let studentToken = null;
  let studentId = null;
  let student2Token = null;
  let student2Id = null;
  let professorToken = null;
  let professorId = null;
  let slotId = null;
  let appointmentId = null;

  let passed = 0;
  let failed = 0;

  const assert = (condition, desc) => {
    if (condition) {
      console.log(`  [PASS] ${desc}`);
      passed++;
    } else {
      console.error(`  [FAIL] ${desc}`);
      failed++;
    }
  };

  try {
    // 1. Register Professor
    console.log("Test Suite 1: Authentication & User Management");
    const profReg = await makeRequest("/users/register", "POST", {
      name: "Professor Xavier",
      email: "xavier@university.edu",
      password: "password123",
      confirmPassword: "password123",
      role: "professor",
    });
    assert(profReg.status === 201, "Professor registration returns 201");
    assert(profReg.data.user && !profReg.data.user.password, "Password is not leaked in registration response");
    professorId = profReg.data.user.id;

    // Login Professor
    const profLogin = await makeRequest("/users/login", "POST", {
      email: "xavier@university.edu",
      password: "password123",
    });
    assert(profLogin.status === 200, "Professor login returns 200");
    assert(profLogin.data.token, "Professor receives JWT token");
    professorToken = profLogin.data.token;

    // Register Student 1
    const studReg = await makeRequest("/users/register", "POST", {
      name: "Peter Parker",
      email: "peter@student.edu",
      password: "studentpass",
      confirmPassword: "studentpass",
      role: "student",
    });
    assert(studReg.status === 201, "Student 1 registration returns 201");
    studentId = studReg.data.user.id;

    // Login Student 1
    const studLogin = await makeRequest("/users/login", "POST", {
      email: "peter@student.edu",
      password: "studentpass",
    });
    assert(studLogin.status === 200, "Student 1 login returns 200");
    studentToken = studLogin.data.token;

    // Register Student 2 (for double booking test)
    const stud2Reg = await makeRequest("/users/register", "POST", {
      name: "Miles Morales",
      email: "miles@student.edu",
      password: "studentpass2",
      confirmPassword: "studentpass2",
      role: "student",
    });
    student2Id = stud2Reg.data.user.id;

    const stud2Login = await makeRequest("/users/login", "POST", {
      email: "miles@student.edu",
      password: "studentpass2",
    });
    student2Token = stud2Login.data.token;

    // Auth Error Check: Invalid token returns 401, not 402
    const invalidTokenRes = await makeRequest("/general/appointments", "GET", null, "invalid.token.here");
    assert(invalidTokenRes.status === 401, "Invalid token returns HTTP 401 (not 402)");

    const noTokenRes = await makeRequest("/general/appointments", "GET");
    assert(noTokenRes.status === 401, "Missing token returns HTTP 401 (not 402)");

    // Profile Authorization Check
    const ownProfile = await makeRequest(`/users/profile/${studentId}`, "GET", null, studentToken);
    assert(ownProfile.status === 200 && ownProfile.data.email === "peter@student.edu", "Student can view own profile");
    assert(!ownProfile.data.password, "Profile does not expose password");

    const otherProfile = await makeRequest(`/users/profile/${professorId}`, "GET", null, studentToken);
    assert(otherProfile.status === 403, "Student viewing another user's profile is blocked with HTTP 403");

    // 2. Role-Based Access Control
    console.log("\nTest Suite 2: Role-Based Authorization");
    // Student attempting to add availability (professor-only)
    const futureDate1 = new Date(Date.now() + 86400000).toISOString();
    const futureDate2 = new Date(Date.now() + 90000000).toISOString();
    const studentAddSlot = await makeRequest("/professor/availability", "POST", {
      startTime: futureDate1,
      endTime: futureDate2,
    }, studentToken);
    assert(studentAddSlot.status === 403, "Student cannot access professor-only POST /professor/availability (HTTP 403)");

    // Professor attempting to book appointment (student-only)
    const profBook = await makeRequest("/general/book", "POST", {
      professorId,
      time: futureDate1,
    }, professorToken);
    assert(profBook.status === 403, "Professor cannot access student-only POST /general/book (HTTP 403)");

    // 3. Professor Adds Availability
    console.log("\nTest Suite 3: Professor Availability Management");
    // Reject past date
    const pastSlot = await makeRequest("/professor/availability", "POST", {
      startTime: "2020-01-01T10:00:00Z",
      endTime: "2020-01-01T11:00:00Z",
    }, professorToken);
    assert(pastSlot.status === 400, "Past availability timing is rejected with HTTP 400");

    // Reject start >= end
    const invalidOrderSlot = await makeRequest("/professor/availability", "POST", {
      startTime: futureDate2,
      endTime: futureDate1,
    }, professorToken);
    assert(invalidOrderSlot.status === 400, "Start time >= end time is rejected with HTTP 400");

    // Successful availability addition (Slot 1: tomorrow + 10h to +11h)
    const slot1Start = new Date(Date.now() + 24 * 3600000);
    const slot1End = new Date(Date.now() + 25 * 3600000);
    const validSlotRes = await makeRequest("/professor/availability", "POST", {
      startTime: slot1Start.toISOString(),
      endTime: slot1End.toISOString(),
    }, professorToken);
    assert(validSlotRes.status === 201, "Professor successfully adds availability slot (HTTP 201)");
    assert(validSlotRes.data.availability._id, "Availability response contains _id");
    assert(validSlotRes.data.availability.isBooked === false, "Slot is initially unbooked (isBooked: false)");
    slotId = validSlotRes.data.availability._id;

    // Overlapping slot rejection
    const overlapSlotRes = await makeRequest("/professor/availability", "POST", {
      startTime: new Date(slot1Start.getTime() + 1800000).toISOString(),
      endTime: new Date(slot1End.getTime() + 1800000).toISOString(),
    }, professorToken);
    assert(overlapSlotRes.status === 400, "Overlapping availability slot is rejected with HTTP 400");

    // 4. Student Views Availability & Empty Appointments
    console.log("\nTest Suite 4: Student Availability & Appointment Listing");
    // Check empty appointments returns 200 with []
    const emptyAppts = await makeRequest("/general/appointments", "GET", null, studentToken);
    assert(emptyAppts.status === 200, "Empty student appointments returns HTTP 200");
    assert(Array.isArray(emptyAppts.data.appointments) && emptyAppts.data.appointments.length === 0, "Empty appointments returns empty array []");

    // Student views professor availability
    const availList = await makeRequest(`/general/professor/${professorId}/availability`, "GET", null, studentToken);
    assert(availList.status === 200, "Student fetches professor availability (HTTP 200)");
    assert(availList.data.availableSlots.length >= 1, "Availability response includes open slots");
    assert(availList.data.availableSlots[0]._id === slotId, "Availability slot includes correct _id");

    // 5. Booking & Double-Booking Prevention
    console.log("\nTest Suite 5: Booking & Double-Booking Prevention");
    const bookTime = new Date(slot1Start.getTime() + 900000).toISOString(); // 15 mins into slot
    const bookRes = await makeRequest("/general/book", "POST", {
      professorId,
      time: bookTime,
    }, studentToken);
    assert(bookRes.status === 201, "Student 1 books appointment successfully (HTTP 201)");
    assert(bookRes.data.appointment.status === "booked", "Appointment status is 'booked'");
    appointmentId = bookRes.data.appointment._id;

    // Check slot is now booked in availability query
    const availAfterBook = await makeRequest(`/general/professor/${professorId}/availability`, "GET", null, studentToken);
    const slotStillOpen = availAfterBook.data.availableSlots.some((s) => s._id === slotId);
    assert(!slotStillOpen, "Booked slot no longer appears in open availability listing");

    // Attempt double booking by Student 2 at the same time
    const doubleBookRes = await makeRequest("/general/book", "POST", {
      professorId,
      time: bookTime,
    }, student2Token);
    assert(doubleBookRes.status === 409, "Double booking same professor slot is rejected with HTTP 409");
    assert(doubleBookRes.data.message && doubleBookRes.data.message.includes("already booked"), "Rejection message clearly indicates slot is already booked");

    // Student 1 views appointments
    const studentAppts = await makeRequest("/general/appointments", "GET", null, studentToken);
    assert(studentAppts.status === 200 && studentAppts.data.appointments.length === 1, "Student 1 sees 1 booked appointment");
    assert(studentAppts.data.appointments[0].professor === "Professor Xavier", "Professor name is populated in student appointments");

    // Test simultaneous concurrent booking attempts on a new slot
    console.log("  Testing simultaneous concurrent booking race condition...");
    const slotCStart = new Date(Date.now() + 100 * 3600000);
    const slotCEnd = new Date(Date.now() + 101 * 3600000);
    const slotCRes = await makeRequest("/professor/availability", "POST", {
      startTime: slotCStart.toISOString(),
      endTime: slotCEnd.toISOString(),
    }, professorToken);
    assert(slotCRes.status === 201, "Created slot C for concurrency race testing");

    const concurrentTime = new Date(slotCStart.getTime() + 600000).toISOString();
    const [simul1, simul2] = await Promise.all([
      makeRequest("/general/book", "POST", { professorId, time: concurrentTime }, studentToken),
      makeRequest("/general/book", "POST", { professorId, time: concurrentTime }, student2Token),
    ]);

    const oneSucceeded = (simul1.status === 201 && simul2.status === 409) || (simul1.status === 409 && simul2.status === 201);
    assert(oneSucceeded, "Simultaneous booking race: Exactly one request succeeded (201) and one was rejected (409)");
    const failedSimul = simul1.status === 409 ? simul1 : simul2;
    assert(failedSimul.data.message && failedSimul.data.message.includes("already booked"), "Concurrent rejection returned clear 'already booked' message");

    // Test failed appointment creation rollback
    console.log("  Testing failed appointment creation rollback of availability slot...");
    const slotDStart = new Date(Date.now() + 110 * 3600000);
    const slotDEnd = new Date(Date.now() + 111 * 3600000);
    const slotDRes = await makeRequest("/professor/availability", "POST", {
      startTime: slotDStart.toISOString(),
      endTime: slotDEnd.toISOString(),
    }, professorToken);
    const slotDId = slotDRes.data.availability._id;
    const slotDTime = new Date(slotDStart.getTime() + 600000).toISOString();

    // Temporarily simulate an unexpected DB failure when saving Appointment
    const originalSave = Appointment.prototype.save;
    Appointment.prototype.save = async function () {
      throw new Error("Simulated database failure during appointment creation");
    };

    const failedBookRes = await makeRequest("/general/book", "POST", {
      professorId,
      time: slotDTime,
    }, studentToken);
    assert(failedBookRes.status === 500, "Simulated appointment creation failure returns HTTP 500");

    // Restore original save method
    Appointment.prototype.save = originalSave;

    // Verify availability slot was safely restored to open state in DB
    const restoredSlot = await Availability.findById(slotDId);
    assert(restoredSlot.status === "open" && restoredSlot.isBooked === false, "Availability slot was safely restored to 'open' and isBooked: false");

    // Verify the slot can now be booked successfully after rollback
    const retryBookRes = await makeRequest("/general/book", "POST", {
      professorId,
      time: slotDTime,
    }, studentToken);
    assert(retryBookRes.status === 201, "Slot can be booked successfully after rollback (HTTP 201)");
    const bookedSlotCheck = await Availability.findById(slotDId);
    assert(bookedSlotCheck.status === "booked" && bookedSlotCheck.isBooked === true, "Slot is now marked 'booked' in DB");

    // 6. Professor Views Appointments
    console.log("\nTest Suite 6: Professor Appointment Listing");
    const profAppts = await makeRequest("/professor/appointments", "GET", null, professorToken);
    assert(profAppts.status === 200, "Professor views appointments returns HTTP 200");
    assert(profAppts.data.appointments.length >= 1, "Professor sees the booked appointments");
    assert(profAppts.data.appointments.some((a) => a._id === appointmentId), "Professor sees the original booked appointment");
    assert(profAppts.data.appointments.some((a) => a.studentName === "Peter Parker"), "Student name is correctly populated");

    // 7. NEW REQUIRED API: PATCH /professor/availability/:slotId
    console.log("\nTest Suite 7: NEW API - PATCH /professor/availability/:slotId");
    // Attempt to update the booked slot -> should be rejected!
    const newSlotStart = new Date(Date.now() + 48 * 3600000);
    const newSlotEnd = new Date(Date.now() + 49 * 3600000);
    const updateBookedRes = await makeRequest(`/professor/availability/${slotId}`, "PATCH", {
      startTime: newSlotStart.toISOString(),
      endTime: newSlotEnd.toISOString(),
    }, professorToken);
    assert(updateBookedRes.status === 400, "Updating a booked slot is rejected with HTTP 400");

    // Create a new FREE slot for update testing
    const freeSlotStart = new Date(Date.now() + 72 * 3600000);
    const freeSlotEnd = new Date(Date.now() + 73 * 3600000);
    const freeSlotRes = await makeRequest("/professor/availability", "POST", {
      startTime: freeSlotStart.toISOString(),
      endTime: freeSlotEnd.toISOString(),
    }, professorToken);
    const freeSlotId = freeSlotRes.data.availability._id;
    assert(freeSlotRes.status === 201, "Created second free slot for PATCH testing");

    // Student attempts to update professor's slot -> 403
    const studentPatchSlot = await makeRequest(`/professor/availability/${freeSlotId}`, "PATCH", {
      startTime: new Date(Date.now() + 80 * 3600000).toISOString(),
      endTime: new Date(Date.now() + 81 * 3600000).toISOString(),
    }, studentToken);
    assert(studentPatchSlot.status === 403, "Student cannot update professor availability slot (HTTP 403)");

    // Professor updates free slot with invalid times (start >= end)
    const patchInvalidTime = await makeRequest(`/professor/availability/${freeSlotId}`, "PATCH", {
      startTime: new Date(Date.now() + 82 * 3600000).toISOString(),
      endTime: new Date(Date.now() + 80 * 3600000).toISOString(),
    }, professorToken);
    assert(patchInvalidTime.status === 400, "Updating slot with start >= end rejected (HTTP 400)");

    // Professor successfully updates the free slot
    const updatedStart = new Date(Date.now() + 84 * 3600000);
    const updatedEnd = new Date(Date.now() + 86 * 3600000);
    const patchSuccess = await makeRequest(`/professor/availability/${freeSlotId}`, "PATCH", {
      startTime: updatedStart.toISOString(),
      endTime: updatedEnd.toISOString(),
    }, professorToken);
    assert(patchSuccess.status === 200, "Professor successfully updates free slot (HTTP 200)");
    assert(patchSuccess.data.availability._id === freeSlotId, "CRITICAL: Slot update PRESERVED original MongoDB _id!");
    assert(new Date(patchSuccess.data.availability.startTime).getTime() === updatedStart.getTime(), "Slot startTime updated correctly");
    assert(new Date(patchSuccess.data.availability.endTime).getTime() === updatedEnd.getTime(), "Slot endTime updated correctly");

    // 8. Cancellation of Specific Appointment
    console.log("\nTest Suite 8: Appointment Cancellation & Slot Re-opening");
    const cancelRes = await makeRequest(`/professor/cancel-appointment/${appointmentId}`, "PATCH", null, professorToken);
    assert(cancelRes.status === 200, "Professor cancels specific appointment by ID (HTTP 200)");
    assert(cancelRes.data.appointment.status === "cancelled", "Cancelled status is spelled 'cancelled'");

    // Verify slot is now reopened
    const reopenedCheck = await makeRequest(`/general/professor/${professorId}/availability`, "GET", null, studentToken);
    const slotReopened = reopenedCheck.data.availableSlots.some((s) => s._id === slotId);
    assert(slotReopened, "Cancelled appointment freed up the availability slot");

    console.log(`\n==========================================`);
    console.log(`TEST SUMMARY: ${passed} Passed, ${failed} Failed`);
    console.log(`==========================================`);
  } catch (err) {
    console.error("Test execution threw error:", err);
    failed++;
  } finally {
    if (server) server.close();
    if (mongoose.connection.readyState) await mongoose.disconnect();
    if (mongod) await mongod.stop();
    process.exit(failed > 0 ? 1 : 0);
  }
};

runTests();
