# Use official Node.js image
FROM node:18

# Set working directory
WORKDIR /app

# Copy all files
COPY server.js .

# Expose port 3000
EXPOSE 3000

# Run the server
CMD ["node", "server.js"]
