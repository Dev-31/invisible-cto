from http.server import HTTPServer, BaseHTTPRequestHandler
import json

class MockOpenAIHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        content_length = int(self.headers.get('Content-Length', 0))
        post_data = self.rfile.read(content_length)
        print("Mock received:", post_data.decode('utf-8'))
        
        response = {
            "id": "mock-123",
            "object": "chat.completion",
            "created": 1234567890,
            "model": "mock-model",
            "choices": [{
                "index": 0,
                "message": {
                    "role": "assistant",
                    "content": '{\n"file_path": "invisible-cto/test_app.py",\n"old_code": "return a + b + c",\n"new_code": "return a + b"\n}'
                },
                "finish_reason": "stop"
            }]
        }
        
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps(response).encode('utf-8'))

if __name__ == "__main__":
    server = HTTPServer(('localhost', 8081), MockOpenAIHandler)
    print("Mock OpenAI server running on port 8081...")
    server.serve_forever()
