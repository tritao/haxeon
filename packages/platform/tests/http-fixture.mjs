import { createServer } from "node:http";

const server = createServer((request, response) => {
	const chunks = [];
	request.on("data", (chunk) => chunks.push(chunk));
	request.on("end", () => {
		const body = Buffer.concat(chunks).toString("utf8");
		const valid = request.method === "POST" && request.url === "/relay/ticket" &&
			request.headers["content-type"] === "application/json" && body === '{"ticket":true}';
		response.writeHead(valid ? 201 : 400, {
			"X-Relay-Token": "alpha",
			"X-Relay-State": "beta",
			"Content-Length": Buffer.byteLength(valid ? "ticket-ok" : "invalid request"),
			"Connection": "close"
		});
		response.end(valid ? "ticket-ok" : "invalid request", () => server.close());
	});
});

server.on("error", (error) => {
	console.error(error);
	process.exitCode = 1;
});
server.listen(0, "127.0.0.1", () => {
	console.log(server.address().port);
});
