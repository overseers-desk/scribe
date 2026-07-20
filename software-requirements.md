## **Language Stylist — Functional Requirements**

### **1. Overview**

Language Stylist is a lightweight, hotkey-invoked desktop tool that transforms the text currently on the clipboard using predefined language or style prompts powered by an LLM service (e.g., DeepSeek).
The application is intended to be minimal, fast, and cross-platform (Windows, macOS, Linux).

---

### **2. Core Behavior**

1. The application is **launched via a global hotkey** (configured externally).

2. Upon launch, it immediately:

   * Reads the **current clipboard text**.
   * Displays the main window showing:

     * The original clipboard text (read-only).
     * A row of **prompt buttons**.
     * An initially empty output area (for the transformed result).

3. The application automatically starts transforming the clipboard text using the **last selected prompt**.

4. While processing:

   * The output area is grayed out and indicates that the transformation is in progress.
   * If the user selects another prompt before the result arrives, the current request is **canceled** and a new one begins immediately.

5. When the transformation completes:

   * The transformed text appears in the output area.
   * A **Copy** button becomes available.
   * The focus is moved to "Copy" button.

6. Clicking the **Copy** button:

   * Copies the transformed text to the clipboard.
   * Immediately exits the application.

**Important** The app is designed that the total amount of interaction in most cases is just user pressing "Enter" key when focus is on the Copy Button. Just one click or one key, is the expected lifespan of interactions.
---

### **3. User Interface Layout**

Stacked vertical layout with three frames:

1. **Top Frame:**

   * Displays the **original clipboard content** (read-only, grayed out).

2. **Middle Frame:**

   * Contains **prompt buttons** labeled by name (e.g., “Formal,” “Friendly,” etc.).
   * There are **up to ten** prompt buttons.
   * Each button triggers a transformation using its associated prompt.
   * Keyboard shortcuts (numbers 1–0) select prompts.

3. **Bottom Frame:**

   * Displays the **transformed text** once ready.
   * Contains the **Copy** button (disabled until output is ready).

---

### **4. Prompt Management**

1. Prompts are stored as **individual text files** in a dedicated folder "prompts"

   * **File name** = prompt label shown on the button (e.g., `puppy_english.txt` displays as "puppy_english").
   * **File content** = the actual LLM system prompt text that defines the transformation behavior.
   * The full content of the selected prompt file is sent as the system message to the DeepSeek API.
2. Prompts are **loaded automatically** on startup.
3. Prompts appear in **alphabetical order** (by filename).
4. The application ships with a **default set of example prompt files**, including:
   * `prompts/puppy_english.txt` — Simplifies text into clear, plain English suitable for general readers following the "PUPPY" principle (*People Understand Plain Points, Yo!*).
5. Users may **add, edit, or remove** prompt files to customize behavior.

---

### **5. Session Persistence**

* The application remembers the **last used prompt**.
* This information is stored in a small configuration file and loaded on startup.

---

### **6. If user didn't copy before calling the app**

* If the clipboard is empty or contains unsupported data, display a simple error message in the top frame, and quite either after a count-down of 3 seconds or if the user click "OK" button.

---

### **7. Termination**

* The application closes automatically after the user clicks the Copy button.

---

### **8. Non-Functional Requirements**

#### **8.1 Technology Stack**

* The application must be implemented in **Tcl 8.6**.
* The code must be compatible with **Tcl 9**, assuming the `tls` library is installed when launched with Tcl 9.
* The application is always launched through **wish** (Tk windowing shell).

#### **8.2 User Interface Framework**

* All UI elements must use **ttk** (themed Tk widgets) unless there is no ttk equivalent available.

#### **8.3 Configuration Files**

1. **Session Configuration:**
   * Stores the last selected prompt.
   * Saved in a small configuration file in the application directory.

2. **DeepSeek API Key:**
   * Stored in `deepseek.json` file.
   * The operator supplies this file from an existing DeepSeek API credential.
   * Format:
     ```json
     {
       "api_key": "your-deepseek-api-key-here",
       "api_base": "https://api.deepseek.com",
       "model": "deepseek-chat"
     }
     ```
   * Note: This is distinct from the session configuration file.

---

### **9. LLM Integration — DeepSeek API**

#### **9.1 API Endpoint**

* **Base URL:** `https://api.deepseek.com`
* **Endpoint:** `/chat/completions`
* **Method:** POST

#### **9.2 Request Format**

**Headers:**
* `Authorization: Bearer {api_key}`
* `Content-Type: application/json`

**Payload (JSON):**
```json
{
  "model": "deepseek-chat",
  "messages": [
    {"role": "system", "content": "{content_from_selected_prompt_file}"},
    {"role": "user", "content": "{clipboard_text}"}
  ],
  "temperature": 0.7,
  "max_tokens": 2000
}
```

**Note:** The `{content_from_selected_prompt_file}` is the full text content read from the selected prompt file (e.g., `prompts/puppy_english.txt`). This defines the transformation behavior. The `{clipboard_text}` is the text to be transformed.

#### **9.3 Response Format**

Successful response returns JSON:
```json
{
  "choices": [
    {
      "message": {
        "content": "transformed text here"
      }
    }
  ],
  "usage": {
    "prompt_tokens": 123,
    "completion_tokens": 456,
    "total_tokens": 579
  }
}
```

Extract the transformed text from: `response['choices'][0]['message']['content']`

#### **9.4 Error Handling**

* **Timeout:** Set request timeout to 30 seconds. Display error message if exceeded.
* **Network errors:** Catch HTTP errors and display user-friendly error messages.
* **API errors:** Handle authentication failures, rate limits, and malformed responses gracefully.
* **Missing API key:** Display error if `deepseek.json` is missing or doesn't contain `api_key`.

#### **9.5 Implementation Notes for Tcl**

* Use `http` and `tls` packages for HTTPS requests.
* Use `json` package for parsing JSON responses.
* For Tcl 8.6: Ensure `tls` package is available and registered with `http`.
* For Tcl 9: The `tls` library must be installed and available.
* Example Tcl HTTP call structure:
  ```tcl
  package require http
  package require tls
  package require json
  
  # Register TLS for HTTPS
  http::register https 443 ::tls::socket
  
  # Prepare headers and payload
  set headers [list Authorization "Bearer $api_key" Content-Type "application/json"]
  set payload [json::write object ...]
  
  # Make POST request
  set token [http::geturl $url -method POST -headers $headers -query $payload -timeout 30000]
  set response_data [http::data $token]
  set status [http::status $token]
  http::cleanup $token
  
  # Parse JSON response
  set response_dict [json::parse $response_data]
  ```
