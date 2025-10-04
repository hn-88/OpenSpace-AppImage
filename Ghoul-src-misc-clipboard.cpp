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
    // (your existing pbpaste version)
#else
#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <unistd.h>
#include <string>
#include <iostream>
#endif

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

#ifdef __linux__

static std::string getSelectionText(Display* d, Atom selection, int timeout_ms = 500) {
    std::string result;

    if (!d) return result;

    Window w = XCreateSimpleWindow(d, DefaultRootWindow(d), 0, 0, 1, 1, 0, 0, 0);
    if (!w) return result;

    Atom utf8 = XInternAtom(d, "UTF8_STRING", False);

    XConvertSelection(d, selection, utf8, selection, w, CurrentTime);

    XEvent event;
    bool done = false;
    int iterations = timeout_ms / 10; // 10 ms per check

    for (int i = 0; i < iterations; ++i) {
        if (XCheckTypedWindowEvent(d, w, SelectionNotify, &event)) {
            if (event.xselection.property) {
                Atom actualType;
                int actualFormat;
                unsigned long nitems, bytesAfter;
                unsigned char* prop = nullptr;

                XGetWindowProperty(
                    d, w, selection, 0, (~0L), False, AnyPropertyType,
                    &actualType, &actualFormat, &nitems, &bytesAfter, &prop
                );

                if (prop) {
                    result.assign(reinterpret_cast<char*>(prop), nitems);
                    XFree(prop);
                }
            }
            done = true;
            break;
        }
        usleep(10000); // 10 ms
    }

    XDestroyWindow(d, w);
    return result;
}

std::string getClipboardText_X11() {
    Display* d = XOpenDisplay(nullptr);
    if (!d) {
        std::cerr << "[Clipboard] Cannot open X display\n";
        return "";
    }

    // Try CLIPBOARD first
    Atom clipboard = XInternAtom(d, "CLIPBOARD", False);
    std::string text = getSelectionText(d, clipboard);
    if (!text.empty()) {
        XCloseDisplay(d);
        return text;
    }

    // Fallback: PRIMARY selection (middle-click copy)
    Atom primary = XInternAtom(d, "PRIMARY", False);
    text = getSelectionText(d, primary);

    XCloseDisplay(d);
    return text; // may be empty if nothing available
}
#endif


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
    return getClipboardText_X11();
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
