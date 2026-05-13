# Use an official Node.js runtime as a parent image
FROM node:22.14-alpine AS builder

WORKDIR /app

# Copy package.json and package-lock.json to the container
COPY package*.json ./

# Install app dependencies
RUN npm install

# Copy the rest of the app source code to the container
COPY . .

# Build arguments for Datadog RUM (passed at build time)
ARG VITE_DATADOG_RUM_ENABLED=false
ARG VITE_DATADOG_RUM_APPLICATION_ID
ARG VITE_DATADOG_RUM_CLIENT_TOKEN
ARG VITE_DATADOG_SITE=us5.datadoghq.com
ARG VITE_DATADOG_SERVICE=store-front
ARG VITE_DATADOG_ENV=production
ARG VITE_APP_VERSION=1.0.0

# Set environment variables for build (Vite bakes VITE_* vars into the bundle)
ENV VITE_DATADOG_RUM_ENABLED=$VITE_DATADOG_RUM_ENABLED
ENV VITE_DATADOG_RUM_APPLICATION_ID=$VITE_DATADOG_RUM_APPLICATION_ID
ENV VITE_DATADOG_RUM_CLIENT_TOKEN=$VITE_DATADOG_RUM_CLIENT_TOKEN
ENV VITE_DATADOG_SITE=$VITE_DATADOG_SITE
ENV VITE_DATADOG_SERVICE=$VITE_DATADOG_SERVICE
ENV VITE_DATADOG_ENV=$VITE_DATADOG_ENV
ENV VITE_APP_VERSION=$VITE_APP_VERSION

# Use build-only (skips type-check) — type-check runs in SonarQube CI step
RUN npm run build-only

# Run the app on nginx
FROM nginx:stable-alpine-slim AS runner

# Copy the build output to replace the default nginx contents
COPY --from=builder /app/dist /usr/share/nginx/html

# Expose the port the app listens on
EXPOSE 8080

# Set the build argument for the app version number
ARG APP_VERSION=0.1.0

# Set the environment variable for the app version number
ENV APP_VERSION=$APP_VERSION

# Copy the nginx configuration template to the container
COPY nginx.conf /etc/nginx/conf.d/nginx.conf.template

# Update the nginx configuration to use the app version number
RUN envsubst '${APP_VERSION}' < /etc/nginx/conf.d/nginx.conf.template > /etc/nginx/conf.d/default.conf

# Start the app
CMD ["nginx", "-g", "daemon off;"]