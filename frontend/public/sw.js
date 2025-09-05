// Empty service worker to prevent 404 errors
// This file exists to handle legacy service worker registrations

self.addEventListener('install', function(event) {
  // Skip waiting and activate immediately
  self.skipWaiting();
});

self.addEventListener('activate', function(event) {
  // Claim all clients and unregister itself
  event.waitUntil(
    clients.claim().then(function() {
      // Unregister this service worker to clean up
      return self.registration.unregister();
    })
  );
});