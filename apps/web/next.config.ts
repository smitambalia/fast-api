import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  // Standalone output for small production Docker image
  output: "standalone",
  // Allow opening the dev server via LAN IP (HMR / stack frames)
  allowedDevOrigins: ["192.168.1.11", "localhost", "127.0.0.1"],
};

export default nextConfig;
