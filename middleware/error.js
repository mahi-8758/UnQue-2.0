
export const notFound = (req, res, next) => {
  const error = new Error(`Not Found - ${req.originalUrl}`);
  res.status(404);
  next(error);
};

export const errorMiddleware = (err, req, res, next) => {
  if (res.headersSent) {
    return next(err);
  }
  const statusCode =
    typeof err.code === "number" && err.code >= 400 && err.code < 600
      ? err.code
      : typeof err.statusCode === "number" && err.statusCode >= 400 && err.statusCode < 600
      ? err.statusCode
      : res.statusCode && res.statusCode >= 400
      ? res.statusCode
      : 500;

  res.status(statusCode).json({
    message: err.message || "An unknown error occurred",
  });
};
