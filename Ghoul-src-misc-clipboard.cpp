/*****************************************************************************************
 *                                                                                       *
 * GHOUL                                                                                 *
 * General Helpful Open Utility Library                                                  *
 *                                                                                       *
 * Copyright (c) 2012-2025                                                               *
 *                                                                                       *
 * Permission is hereby granted, free of charge, to any person obtaining a copy of this  *
 * software and associated documentation files (the "Software"), to deal in the Software *
 * without restriction, including without limitation the rights to use, copy, modify,    *
 * merge, publish, distribute, sublicense, and/or sell copies of the Software, and to    *
 * permit persons to whom the Software is furnished to do so, subject to the following   *
 * conditions:                                                                           *
 *                                                                                       *
 * The above copyright notice and this permission notice shall be included in all copies *
 * or substantial portions of the Software.                                              *
 *                                                                                       *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,   *
 * INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A         *
 * PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT    *
 * HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF  *
 * CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE  *
 * OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.                                         *
 ****************************************************************************************/

#include <ghoul/misc/clipboard.h>

#include <ghoul/misc/exception.h>
#include <ghoul/format.h>
#include <algorithm>
#include <sstream>

#ifdef WIN32
#include <Windows.h>
#elif defined(__APPLE__)
#else
#include <iostream>
// for getClipboardTextX11()
#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <poll.h>
#include <unistd.h>
#include <cstring>
#include <string>

extern "C" Display* getOpenSpaceDisplay();

namespace {

std::string getClipboardTextX11() {
    std::cerr << "=== Querying clipboard ===" << std::endl;
    
    Display* display = getOpenSpaceDisplay();
    if (!display) {
        std::cerr << "ERROR: Failed to open display" << std::endl;
        return "";
    }
    
    // Create window
    Window window = XCreateSimpleWindow(display, DefaultRootWindow(display),
                                        -10, -10, 1, 1, 0, 0, 0);
    
    // Map the window - Chrome requires this
    XSelectInput(display, window, PropertyChangeMask | StructureNotifyMask);
    XMapWindow(display, window);
    
    // Wait for MapNotify
    XEvent mapEvent;
    while (true) {
        XNextEvent(display, &mapEvent);
        if (mapEvent.type == MapNotify) {
            std::cerr << "Window mapped" << std::endl;
            break;
        }
    }
    
    Atom clipboard = XInternAtom(display, "CLIPBOARD", False);
    Atom utf8 = XInternAtom(display, "UTF8_STRING", False);
    Atom text = XInternAtom(display, "TEXT", False);
    Atom stringAtom = XInternAtom(display, "STRING", False);
    Atom incr = XInternAtom(display, "INCR", False);
    Atom property = XInternAtom(display, "GHOUL_CLIP_TEMP", False);
    
    std::cerr << "Requesting clipboard..." << std::endl;
    XConvertSelection(display, clipboard, utf8, property, window, CurrentTime);
    XSync(display, False);
    
    std::string result;
    bool incrMode = false;
    std::vector<unsigned char> incrData;
    bool gotSelectionNotify = false;
    
    auto startTime = std::chrono::steady_clock::now();
    const int totalTimeout = 2000;
    
    while (true) {
        auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - startTime).count();
        int remainingTimeout = totalTimeout - elapsed;
        
        if (remainingTimeout <= 0) {
            std::cerr << "Timeout waiting for clipboard" << std::endl;
            break;
        }
        
        // Process all queued events first
        while (XPending(display) > 0) {
            XEvent event;
            XNextEvent(display, &event);
            
            std::cerr << "Event type: " << event.type;
            
            if (event.type == SelectionNotify) {
                std::cerr << " (SelectionNotify)" << std::endl;
                gotSelectionNotify = true;
                std::cerr << "  window=" << event.xselection.requestor 
                         << " (ours=" << window << ")" << std::endl;
                std::cerr << "  property=" << event.xselection.property 
                         << " (expected=" << property << ")" << std::endl;
                
                if (event.xselection.property == None) {
                    std::cerr << "  Conversion failed" << std::endl;
                    goto cleanup;
                }
                
                Atom actualType;
                int actualFormat;
                unsigned long nitems, bytesAfter;
                unsigned char* data = nullptr;
                
                int status = XGetWindowProperty(display, window, property, 0, (~0L), False,
                                 AnyPropertyType, &actualType, &actualFormat,
                                 &nitems, &bytesAfter, &data);
                
                char* typeName = XGetAtomName(display, actualType);
                std::cerr << "  status=" << status << ", type=" << (typeName ? typeName : "null") 
                         << ", nitems=" << nitems << ", bytesAfter=" << bytesAfter << std::endl;
                
                if (actualType == incr) {
                    std::cerr << "  INCR mode activated" << std::endl;
                    incrMode = true;
                    XDeleteProperty(display, window, property);
                    XFlush(display);
                    if (data) XFree(data);
                    if (typeName) XFree(typeName);
                    continue;
                }
                
                bool isTextType = (actualType == utf8 || actualType == text || 
                                  actualType == stringAtom);
                
                if (!isTextType) {
                    std::cerr << "  Non-text data" << std::endl;
                    if (typeName) XFree(typeName);
                    if (data) XFree(data);
                    goto cleanup;
                }
                
                if (data && nitems > 0) {
                    result.assign(reinterpret_cast<char*>(data), nitems);
                    std::cerr << "  Got " << result.size() << " bytes directly" << std::endl;
                    XFree(data);
                    if (typeName) XFree(typeName);
                    goto cleanup;
                }
                
                if (typeName) XFree(typeName);
                if (data) XFree(data);
            }
            else if (event.type == PropertyNotify) {
                std::cerr << " (PropertyNotify)";
                std::cerr << " window=" << event.xproperty.window 
                         << " (ours=" << window << ")";
                std::cerr << " atom=" << event.xproperty.atom 
                         << " (property=" << property << ")";
                std::cerr << " state=" << event.xproperty.state 
                         << " (NewValue=" << PropertyNewValue << ")" << std::endl;
                
                // CHECK: Is this PropertyNotify for our property?
                if (event.xproperty.window != window || event.xproperty.atom != property) {
                    std::cerr << "  Not our property, ignoring" << std::endl;
                    continue;
                }
                
                // Only process PropertyNotify if we're in INCR mode
                if (!incrMode) {
                    std::cerr << "  Not in INCR mode yet - checking property anyway" << std::endl;
                    
                    // Maybe Chrome set the property without SelectionNotify?
                    // Let's check what's there
                    Atom actualType;
                    int actualFormat;
                    unsigned long nitems, bytesAfter;
                    unsigned char* data = nullptr;
                    
                    int status = XGetWindowProperty(display, window, property, 0, (~0L), False,
                                     AnyPropertyType, &actualType, &actualFormat,
                                     &nitems, &bytesAfter, &data);
                    
                    char* typeName = XGetAtomName(display, actualType);
                    std::cerr << "  Property contains: type=" << (typeName ? typeName : "null")
                             << ", nitems=" << nitems << std::endl;
                    
                    if (actualType == incr) {
                        std::cerr << "  Found INCR without SelectionNotify! Activating INCR mode" << std::endl;
                        incrMode = true;
                        gotSelectionNotify = true;  // Pretend we got it
                        XDeleteProperty(display, window, property);
                        XFlush(display);
                        if (data) XFree(data);
                        if (typeName) XFree(typeName);
                        continue;
                    }
                    
                    if (typeName) XFree(typeName);
                    if (data) XFree(data);
                    continue;
                }
                
                if (event.xproperty.state != PropertyNewValue) {
                    continue;
                }
                
                std::cerr << "  PropertyNotify in INCR mode" << std::endl;
                
                Atom actualType;
                int actualFormat;
                unsigned long nitems, bytesAfter;
                unsigned char* data = nullptr;
                
                XGetWindowProperty(display, window, property, 0, (~0L), True,
                                 AnyPropertyType, &actualType, &actualFormat,
                                 &nitems, &bytesAfter, &data);
                
                if (incrData.empty() && nitems > 0) {
                    bool isTextType = (actualType == utf8 || actualType == text || 
                                      actualType == stringAtom);
                    if (!isTextType) {
                        char* typeName = XGetAtomName(display, actualType);
                        std::cerr << "  Non-text INCR data: " << (typeName ? typeName : "null") << std::endl;
                        if (typeName) XFree(typeName);
                        if (data) XFree(data);
                        goto cleanup;
                    }
                }
                
                if (nitems == 0) {
                    std::cerr << "  INCR complete: " << incrData.size() << " bytes" << std::endl;
                    result.assign(reinterpret_cast<char*>(incrData.data()), 
                                incrData.size());
                    if (data) XFree(data);
                    goto cleanup;
                }
                
                if (data) {
                    incrData.insert(incrData.end(), data, data + nitems);
                    std::cerr << "  INCR chunk: " << nitems << " bytes (total: " 
                             << incrData.size() << ")" << std::endl;
                    XFree(data);
                }
            }
            else {
                std::cerr << " (other)" << std::endl;
            }
        }
        
        // Wait for more events
        struct pollfd pfd = { ConnectionNumber(display), POLLIN, 0 };
        int pollResult = poll(&pfd, 1, remainingTimeout);
        
        if (pollResult <= 0) {
            std::cerr << "Poll timeout" << std::endl;
            break;
        }
    }
    
cleanup:
    XDeleteProperty(display, window, property);
    XDestroyWindow(display, window);
    XCloseDisplay(display);
    
    std::cerr << "=== Returning " << result.size() << " bytes ===" << std::endl;
    return result;
} // getClipboardTextX11()

} // namespace

#endif 
// end if not Win32 and not APPLE

namespace {
#ifndef WIN32
   // This is called with a specific input, but has the potential to be very dangerous
    bool exec(const std::string& cmd, std::string& value) {
        FILE* pipe = popen(cmd.c_str(), "r");
        if (!pipe) {
            return false;
        }

        constexpr int BufferSize = 1024;
        std::array<char, BufferSize> buffer = {};
        value.clear();
        while (!feof(pipe)) {
            if (fgets(buffer.data(), BufferSize, pipe) != nullptr) {
                value += buffer.data();
            }
        }
        pclose(pipe);
        return true;
    }
#endif
} // namespace

namespace ghoul {

std::string clipboardText() {
   // debug
   std::cerr << "Entered clipboardText()" << std::endl;
#ifdef WIN32
    // Try opening the clipboard
    if (!OpenClipboard(nullptr)) {
        return "";
    }

    // Get handle of clipboard object for ANSI text
    HANDLE hData = GetClipboardData(CF_TEXT);
    if (!hData) {
        return "";
    }

    // Lock the handle to get the actual text pointer
    char* pszText = static_cast<char*>(GlobalLock(hData));
    if (!pszText) {
        return "";
    }

    // Save text in a string class instance
    std::string text(pszText);

    // Release the lock
    GlobalUnlock(hData);

    // Release the clipboard
    CloseClipboard();

    text.erase(std::remove(text.begin(), text.end(), '\r'), text.end());
    return text;
#elif defined(__APPLE__)
    std::string text;
    if (exec("pbpaste", text)) {
        return text.substr(0, text.length()); // remove a line ending
    }
    return "";
#else
    std::string text;
    const bool isWayland = (std::getenv("WAYLAND_DISPLAY") != nullptr);

    if (isWayland) {
        if (exec("wl-paste --no-newline", text) && !text.empty()) {
            return text;
        }
    }

    // fallback to X11
    text = getClipboardTextX11();
    if (!text.empty() && text.back() == '\n') text.pop_back();
    return text;
#endif
}

void setClipboardText(const std::string& text) {
#ifdef WIN32
    HANDLE hData = GlobalAlloc(GMEM_MOVEABLE | GMEM_DDESHARE, text.length() + 1);
    if (!hData) {
        throw RuntimeError("Error allocating memory", "Clipboard");
    }

    char* ptrData = static_cast<char*>(GlobalLock(hData));
    if (!ptrData) {
        GlobalFree(hData);
        throw RuntimeError("Error acquiring lock", "Clipboard");
    }
    std::memcpy(ptrData, text.c_str(), text.length() + 1);

    GlobalUnlock(hData);

    if (!OpenClipboard(nullptr)) {
        throw RuntimeError("Error opening clipboard", "Clipboard");
    }

    if (!EmptyClipboard()) {
        throw RuntimeError("Error cleaning clipboard", "Clipboard");
    }

    SetClipboardData(CF_TEXT, hData);
    CloseClipboard();
#elif defined(__APPLE__)
    std::string buf;
    bool success = exec(std::format("echo \"{}\" | pbcopy", text), buf);
    if (!success) {
        throw RuntimeError("Error setting text to clipboard", "Clipboard");
    }
#else
    std::string buf;
    const bool success = exec(std::format("echo \"{}\" | xclip -i -sel c -f", text), buf);
    if (!success) {
        throw RuntimeError("Error setting text to clipboard", "Clipboard");
    }
#endif
}

} // namespace ghoul
