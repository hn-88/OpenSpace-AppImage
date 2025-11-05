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
#endif

namespace {

std::string getClipboardTextX11() {
    std::cerr << "Entered getClipboardTextX11()" << std::endl;
    Display* display = XOpenDisplay(nullptr);
    if (!display) {
        std::cerr << "Failed to open display" << std::endl;
        return "";
    }
    
    Window window = XCreateSimpleWindow(display, DefaultRootWindow(display),
                                        0, 0, 1, 1, 0, 0, 0);
    
    Atom clipboard = XInternAtom(display, "CLIPBOARD", False);
    Atom utf8 = XInternAtom(display, "UTF8_STRING", False);
    Atom incr = XInternAtom(display, "INCR", False);
    Atom property = XInternAtom(display, "GHOUL_CLIP_TEMP", False);
    
    // Select PropertyNotify events for INCR transfers
    XSelectInput(display, window, PropertyChangeMask);
    
    // Request clipboard conversion
    XConvertSelection(display, clipboard, utf8, property, window, CurrentTime);
    XFlush(display);
    
    std::string result;
    bool incrMode = false;
    std::vector<unsigned char> incrData;
    
    // Wait for events with timeout
    auto startTime = std::chrono::steady_clock::now();
    const int totalTimeout = 1000; // 1 second total timeout
    
    while (true) {
        auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - startTime).count();
        int remainingTimeout = totalTimeout - elapsed;
        
        if (remainingTimeout <= 0) {
            std::cerr << "Clipboard read timeout" << std::endl;
            break;
        }
        
        struct pollfd pfd = { ConnectionNumber(display), POLLIN, 0 };
        int pollResult = poll(&pfd, 1, remainingTimeout);
        
        if (pollResult <= 0) {
            std::cerr << "Poll timeout or error" << std::endl;
            break;
        }
        
        XEvent event;
        XNextEvent(display, &event);
        
        if (event.type == SelectionNotify) {
            std::cerr << "Received SelectionNotify" << std::endl;
            
            if (event.xselection.property == None) {
                std::cerr << "Conversion failed" << std::endl;
                break;
            }
            
            Atom actualType;
            int actualFormat;
            unsigned long nitems, bytesAfter;
            unsigned char* data = nullptr;
            
            XGetWindowProperty(display, window, property, 0, (~0L), False,
                             AnyPropertyType, &actualType, &actualFormat,
                             &nitems, &bytesAfter, &data);
            
            if (actualType == incr) {
                // INCR protocol - data will come via PropertyNotify events
                std::cerr << "Using INCR protocol" << std::endl;
                incrMode = true;
                XDeleteProperty(display, window, property);
                if (data) XFree(data);
                XFlush(display);
                continue;
            }
            
            if (data) {
                std::cerr << "Got data directly (non-INCR)" << std::endl;
                result.assign(reinterpret_cast<char*>(data), nitems);
                XFree(data);
                break;
            }
        }
        else if (event.type == PropertyNotify && incrMode) {
            if (event.xproperty.state != PropertyNewValue) {
                continue;
            }
            
            Atom actualType;
            int actualFormat;
            unsigned long nitems, bytesAfter;
            unsigned char* data = nullptr;
            
            XGetWindowProperty(display, window, property, 0, (~0L), True,
                             AnyPropertyType, &actualType, &actualFormat,
                             &nitems, &bytesAfter, &data);
            
            if (nitems == 0) {
                // Empty property signals end of INCR transfer
                std::cerr << "INCR transfer complete, " << incrData.size() 
                          << " bytes" << std::endl;
                result.assign(reinterpret_cast<char*>(incrData.data()), 
                            incrData.size());
                if (data) XFree(data);
                break;
            }
            
            if (data) {
                // Append chunk to our buffer
                incrData.insert(incrData.end(), data, data + nitems);
                XFree(data);
            }
        }
    }
    
    XDeleteProperty(display, window, property);
    XDestroyWindow(display, window);
    XCloseDisplay(display);
    
    return result;
}
} // namespace


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
