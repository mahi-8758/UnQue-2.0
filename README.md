# UnQue 2.0

UnQue 2.0 is a REST API for managing student-professor appointments. Professors publish future availability, students reserve open time slots, and either side of the workflow can retrieve appointment information through role-protected endpoints.

The application is built with Node.js, Express, Amazon DocumentDB, and Mongoose. It is API-only; no frontend is included in this repository.

## Features

- Student and professor account registration and login
- JWT-based authentication with two-day token expiry
- Role-based access control for professor and student operations
- Professor availability creation and in-place editing
- Student availability browsing and appointment booking
- Atomic availability claiming to prevent double booking
- Appointment listing and professor-side cancellation
- Password hashing with `bcryptjs`
- Security headers with Helmet, request logging with Morgan, and CORS support
- End-to-end API verification against an ephemeral MongoDB instance
- Optional AWS deployment provisioning scripts for the `ap-south-1` region

## Technology stack

- **Runtime:** Node.js (ES modules)
- **Framework:** Express 4
- **Database:** Amazon DocumentDB through Mongoose 8
- **Authentication:** JSON Web Tokens (`jsonwebtoken`)
- **Password security:** `bcryptjs`
- **Date handling:** `moment`
- **Testing:** Node HTTP client and `mongodb-memory-server`
- **Deployment helpers:** Bash and AWS CLI

## Project structure

```text
.
├── controllers/        Request handlers and business rules
├── middleware/         Authentication, authorization, and error handling
├── models/             Mongoose schemas
├── routes/             Express route definitions
├── scripts/            AWS preflight and infrastructure scripts
├── test/               API verification test
├── .env.example        Local environment variable template
├── index.js            Express app and database startup entry point
└── package.json        Scripts and dependencies
```

## Prerequisites

- Node.js 18 or newer (Node.js 18 or 20 LTS is recommended by the deployment preflight script)
- npm
- A database connection, either:
  - a local MongoDB server for development, or
  - an Amazon DocumentDB cluster for deployment

The test command downloads or starts an ephemeral MongoDB through `mongodb-memory-server`; a separate local database is not required for tests. Amazon DocumentDB is the intended deployment database.

## Installation

```bash
git clone <repository-url>
cd UnQue-2.0
npm install
```

Create a local `.env` file from the template:

```bash
cp .env.example .env
```

On Windows PowerShell, use:

```powershell
Copy-Item .env.example .env
```

Update the values for your environment:

```dotenv
PORT=5001
MONGO_URL=mongodb://localhost:27017/unque
JWT_SECRET=replace-with-a-long-random-secret
NODE_ENV=development
```

Never use the example JWT secret in a deployed environment, and do not commit `.env` files or private keys.

## Running the API

Production-style start:

```bash
npm start
```

Development mode with automatic restart:

```bash
npm run dev
```

The API listens on `http://localhost:5001` by default, or on the port specified by `PORT`. The server connects to the configured database before it starts accepting requests. For local development, `MONGO_URL` can point to MongoDB. For deployment, it should contain the Amazon DocumentDB connection string, including the required TLS and authentication options for the cluster. If `MONGO_URL` is missing or the database connection fails, startup exits with an error.

## Authentication

Register or log in through `/users`. Login returns a JWT. Send it on protected requests using:

```http
Authorization: Bearer <token>
```

Tokens contain the user ID, name, and role and expire after two days. The API accepts the roles `student` and `professor`.

## API reference

All request bodies use JSON. Dates should be supplied in a format accepted by JavaScript's `Date` parser; ISO 8601 UTC strings are recommended.

### User endpoints

| Method | Path | Auth | Description |
|---|---|---|---|
| `POST` | `/users/register` | Public | Create a student or professor account |
| `POST` | `/users/login` | Public | Authenticate and receive a JWT |
| `GET` | `/users/profile/:id` | Any authenticated user | Retrieve only the authenticated user's own profile |

Registration body:

```json
{
  "name": "Ada Professor",
  "email": "ada@example.com",
  "password": "password123",
  "confirmPassword": "password123",
  "role": "professor"
}
```

`role` must be `professor` or `student`. Passwords must contain at least four characters and must match `confirmPassword`. Registration and profile responses do not expose the password.

Login body:

```json
{
  "email": "ada@example.com",
  "password": "password123"
}
```

### Professor endpoints

Every professor endpoint requires a valid professor JWT.

| Method | Path | Description |
|---|---|---|
| `POST` | `/professor/availability` | Add a future, non-overlapping availability slot |
| `PATCH` | `/professor/availability/:slotId` | Edit an unbooked slot without changing its ID |
| `GET` | `/professor/appointments` | List appointments for the authenticated professor |
| `PATCH` | `/professor/cancel-appointment/:appointmentId` | Cancel one appointment and reopen its slot |
| `PATCH` | `/professor/cancel-appointments/:studentId` | Cancel all active appointments with a student |

Create or update availability:

```json
{
  "startTime": "2030-01-15T10:00:00.000Z",
  "endTime": "2030-01-15T11:00:00.000Z"
}
```

Availability must be in the future, have a start before its end, and not overlap another active slot belonging to the professor. Booked slots cannot be edited.

### Student endpoints

Every student endpoint requires a valid student JWT.

| Method | Path | Description |
|---|---|---|
| `GET` | `/general/professor/:professorId/availability` | List future open slots for a professor |
| `POST` | `/general/book` | Book an open time within a professor's availability |
| `GET` | `/general/appointments` | List the authenticated student's active appointments |

Book an appointment:

```json
{
  "professorId": "<professor-object-id>",
  "time": "2030-01-15T10:30:00.000Z"
}
```

Bookings must be in the future and inside an open availability slot. A student cannot create duplicate active bookings at the same time. The availability update is conditional and the database has a partial unique index for active professor/time bookings, protecting the booking flow from concurrent requests.

### Responses and errors

Successful responses use standard JSON objects and commonly return `200`, `201`, or an empty list when no appointments exist. Errors use this shape:

```json
{
  "message": "Description of the error"
}
```

Typical status codes are:

- `400` — malformed input, invalid dates, past times, or unavailable operations
- `401` — missing or invalid JWT
- `403` — wrong role or access to another user's resource
- `404` — missing route or resource
- `409` — booking conflict
- `422` — registration validation failure
- `500` — unexpected server/database error

## Data model

### User

- `name`
- `email` (unique, normalized to lowercase)
- `password` (stored as a bcrypt hash)
- `role` (`student` or `professor`)
- timestamps

### Availability

- `professorId`
- `startTime`
- `endTime`
- `status` (`open`, `booked`, or `cancelled`)
- `isBooked`
- timestamps

### Appointment

- `studentId`
- `professorId`
- optional `availabilityId`
- `time`
- `status` (`booked`, `completed`, or `cancelled`)
- timestamps

Active appointments have a unique `{ professorId, time }` constraint. Cancelling an appointment marks it cancelled and reopens its associated availability slot. The schemas use MongoDB-compatible Mongoose features supported by Amazon DocumentDB.

## Testing

Run the API verification suite:

```bash
npm test
```

The test suite starts an in-memory MongoDB instance and an HTTP server on an ephemeral port. It verifies registration, login, profile authorization, role restrictions, availability validation, booking, double-booking protection, appointment listing, slot updates, cancellation, and rollback behavior.

## AWS deployment helpers

The `scripts/` directory contains Bash helpers for an AWS deployment targeting `ap-south-1` (Mumbai):

1. `00-preflight.sh` — read-only checks for AWS CLI, credentials, Node.js, npm, and region
2. `01-network.sh` — network resource provisioning
3. `02-documentdb.sh` — Amazon DocumentDB provisioning
4. `03-ec2.sh` — EC2 provisioning and application setup

Review each script and its required variables before running it. These scripts require Bash and AWS CLI and are not part of the local development workflow. Keep AWS environment files and `.pem` keys private; the repository's ignore rules exclude them.

## Security and operational notes

- Use a strong, unique `JWT_SECRET` outside local development.
- Use HTTPS and a restricted CORS policy in production rather than the current permissive default.
- Protect Amazon DocumentDB with authentication, private network controls, and TLS as appropriate for the deployment.
- Do not commit `.env` files, AWS credentials, database credentials, or private keys.
- The API logs requests with Morgan; ensure production log storage and retention comply with your operational requirements.
- Validate and monitor database connectivity before exposing the service publicly.

## License

This project currently declares the `ISC` license in `package.json`.
