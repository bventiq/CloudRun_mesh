const { MongoClient } = require('mongodb');
const fs = require('fs');

// Read .env manually to find MONGO_URL
try {
    const envContent = fs.readFileSync('.env', 'utf-8');
    // Handle both export MONGO_URL="value" and MONGO_URL="value"
    const match = envContent.match(/(?:export\s+)?MONGO_URL="([^"]+)"/);

    if (!match) {
        console.error("Could not find MONGO_URL in .env");
        process.exit(1);
    }

    const url = match[1];
    console.log("Testing connection to:", url.replace(/:([^:@]+)@/, ':****@'));

    const client = new MongoClient(url);

    async function run() {
        try {
            await client.connect();
            console.log("✅ SUCCESS: Connection Established!");
            await client.db("admin").command({ ping: 1 });
            console.log("✅ SUCCESS: Ping command execution confirmed.");
        } catch (e) {
            console.error("❌ FAILURE: Connection Failed.");
            console.error("Error Name:", e.name);
            console.error("Error Message:", e.message);
            if (e.codeName) console.error("CodeName:", e.codeName);
        } finally {
            await client.close();
        }
    }
    run();

} catch (err) {
    console.error("Error reading .env:", err.message);
}
