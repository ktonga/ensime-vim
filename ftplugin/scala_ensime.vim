python <<EOF
import vim
import json
import socket
import os
import subprocess
import re
import base64
import logging
from socket import error as socket_error
class Ensime(object):
    def __init__(self, vim):
        self.ensime_cache = ".ensime_cache/"
        log_dir = "/tmp/"
        if os.path.isdir(self.ensime_cache): log_dir = self.ensime_cache
        logging.basicConfig(filename="ensime-vim.log")
        self.logger = logging.getLogger("ensime-vim")
        self.logger.info("__init__: in")
        self.callId = 0
        self.browse = False
        self.vim = vim
        self.matches = []
        self.vim.command("highlight EnError ctermbg=red")
        self.is_setup = False
        self.suggests = None
        self.no_teardown = False
    def ensime_bridge(self, action):
        binary = os.environ.get("ENSIME_BRIDGE")
        if binary == None: binary = "ensime_bridge"
        binary = (binary + " " + action)
        self.logger.info("ensime_bridge: lanching " + binary) 
        subprocess.Popen(binary.split())
    def teardown(self, filename):
        self.logger.info("teardown: in")
        if not self.no_teardown:
            self.ensime_bridge("stop")
    def setup(self):
        self.logger.info("setup: in")
        if not self.is_setup:
            self.ensime_bridge("--quiet")
            self.vim.command("set completefunc=EnCompleteFunc")
            self.is_setup = True
    def get_cache_port(self, where):
        self.logger.info("get_cache_port: in")
        f = open(".ensime_cache/" + where)
        port = f.read()
        f.close()
        return port.replace("\n", "")
    def get_socket(self):
        self.logger.info("get_socket: in")
        try:
            s = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
            port = self.get_cache_port("bridge")
            s.connect(("::1", int(port)))
            return s
        except IOError:
            return None
        except socket_error:
            return None
    def send(self, what):
        self.logger.info("send: in")
        s = self.get_socket()
        if s == None: return
        s.send(what + "\n")
        s.close()
    def cursor(self):
        self.logger.info("cursor: in")
        return self.vim.current.window.cursor
    def path(self):
        self.logger.info("path: in")
        return self.vim.current.buffer.name
    def path_start_size(self, what):
        self.logger.info("path_start_size: in")
        self.vim.command("normal e")
        e = self.cursor()[1]
        self.vim.command("normal b")
        b = self.cursor()[1]
        s = e - b
        self.send('{} "{}", {}, {}, {}'.format(what,
            self.path(), self.cursor()[0], b + 1, s))
    def complete(self):
        self.logger.info("complete: in")
        content = self.vim.eval('join(getline(1, "$"), "\n")')
        content = base64.b64encode(content).replace("\n", "!EOL!")
        self.send('complete "{}", {}, {}, "{}"'.format(self.path(),
            self.cursor()[0], self.cursor()[1] + 1, content))
    def do_no_teardown(self, args, range = None):
        self.logger.info("do_no_teardown: in")
        self.no_teardown = True
    def type_check_cmd(self, args, range = None):
        self.logger.info("type_check_cmd: in")
        self.type_check("")
    def type(self, args, range = None):
        self.logger.info("type: in")
        self.path_start_size("type")
    def doc_uri(self, args, range = None):
        self.logger.info("doc_uri: in")
        self.path_start_size("doc_uri")
    def doc_browse(self, args, range = None) :
        self.logger.info("browse: in")
        self.browse = True
        self.doc_uri(args, range = None)
    def read_line(self, s):
        self.logger.info("read_line: in")
        ret = ''
        while True:
            c = s.recv(1)
            if c == '\n' or c == '':
                break
            else:
                ret += c
        return ret
    def message(self, m):
        self.logger.info("message: in")
        self.vim.command("echo '{}'".format(m))
    def handle_payload(self, payload):
        self.logger.info("handle_payload: in")
        typehint = payload["typehint"]
        if typehint == "IndexerReadyEvent":
            self.message("ensime indexer ready")
        if typehint == "AnalyzerReadyEvent":
            self.message("ensime analyzer ready")
        if typehint == "NewScalaNotesEvent":
            notes = payload["notes"]
            for note in notes:
                l = note["line"]
                c = note["col"] - 1
                e = note["col"] + (note["end"] - note["beg"])
                self.matches.append(self.vim.eval(
                    "matchadd('EnError', '\\%{}l\\%>{}c\\%<{}c')".format(l, c, e)))
                self.message(note["msg"])
        elif typehint == "BasicTypeInfo":
            self.message(payload["fullName"])
        elif typehint == "StringResponse":
            url = "http://127.0.0.1:{}/{}".format(self.get_cache_port("http"),
                    payload["text"])
            if self.browse:
                subprocess.Popen([os.environ.get("BROWSER"), url])
                self.browse = False
            self.message(url)
        elif typehint == "CompletionInfoList":
            self.suggests = [completion["name"] for completion in payload["completions"]]
    def send_request(self, request):
        self.logger.info("send_request: in")
        self.send(json.dumps({"callId" : self.callId,"req" : request}))
        self.callId += 1
    def type_check(self, filename):
        self.logger.info("type_check: in")
        self.send_request({"typehint": "TypecheckFilesReq",
            "files" : [self.path()]})
        for i in self.matches:
            self.vim.eval("matchdelete({})".format(i))
        self.matches = []
    def unqueue(self, filename):
        self.logger.info("unqueue: in")
        self.setup()
        s = self.get_socket()
        if s == None: return
        s.send("unqueue\n")
        while True:
            result = self.read_line(s)
            self.logger.info("unqueue: result received {}".format(str(result)))
            if result == None or result == "nil":
                self.logger.info("unqueue: nil or None received")
                break
            _json = json.loads(result)
            if _json["payload"] != None:
                self.handle_payload(_json["payload"])
        self.logger.info("unqueue: before close")
        s.close()
        self.logger.info("unqueue: after close")
    def autocmd_handler(self, filename):
        self._increment_calls()
        self.vim.current.line = (
            'Autocmd: Called %s times, file: %s' % (self.calls, filename))
    def complete_func(self, args):
        if args[0] == '1':
            self.complete()
            line = self.vim.eval("getline('.')")
            start = self.cursor()[1] - 1
            pattern = re.compile('\a')
            while start > 0 and pattern.match(line[start - 1]):
                start -= 1
            return start
        else:
            while True:
                if self.suggests != None:
                    break
                self.unqueue("")
            result = []
            pattern = re.compile('^' + args[1])
            for m in self.suggests:
                if pattern.match(m):
                    result.append(m)
            self.suggests = None
            return result
plugin = Ensime(vim)
EOF
fun! EnCompleteFunc(arg0, arg1)
python <<EOF
r = plugin.complete_func([vim.eval('a:arg0'), vim.eval('a:arg1')])
vim.command('let g:__result = ' + json.dumps(([] if r == None else r)))
EOF
let res = g:__result
unlet g:__result
return res
endfun
fun! Enteardown(arg0, arg1)
python <<EOF
r = plugin.teardown([vim.eval('a:arg0'), vim.eval('a:arg1')])
vim.command('let g:__result = ' + json.dumps(([] if r == None else r)))
EOF
let res = g:__result
unlet g:__result
return res
endfun
fun! Entype_check(arg0, arg1)
python <<EOF
r = plugin.type_check([vim.eval('a:arg0'), vim.eval('a:arg1')])
vim.command('let g:__result = ' + json.dumps(([] if r == None else r)))
EOF
let res = g:__result
unlet g:__result
return res
endfun
fun! Enunqueue(arg0, arg1)
python <<EOF
r = plugin.unqueue([vim.eval('a:arg0'), vim.eval('a:arg1')])
vim.command('let g:__result = ' + json.dumps(([] if r == None else r)))
EOF
let res = g:__result
unlet g:__result
return res
endfun
fun! Endo_no_teardown(arg0, arg1)
python <<EOF
r = plugin.do_no_teardown([vim.eval('a:arg0'), vim.eval('a:arg1')])
vim.command('let g:__result = ' + json.dumps(([] if r == None else r)))
EOF
let res = g:__result
unlet g:__result
return res
endfun
fun! Entype_check_cmd(arg0, arg1)
python <<EOF
r = plugin.type_check_cmd([vim.eval('a:arg0'), vim.eval('a:arg1')])
vim.command('let g:__result = ' + json.dumps(([] if r == None else r)))
EOF
let res = g:__result
unlet g:__result
return res
endfun
fun! Entype(arg0, arg1)
python <<EOF
r = plugin.type([vim.eval('a:arg0'), vim.eval('a:arg1')])
vim.command('let g:__result = ' + json.dumps(([] if r == None else r)))
EOF
let res = g:__result
unlet g:__result
return res
endfun
fun! Endoc_uri(arg0, arg1)
python <<EOF
r = plugin.doc_uri([vim.eval('a:arg0'), vim.eval('a:arg1')])
vim.command('let g:__result = ' + json.dumps(([] if r == None else r)))
EOF
let res = g:__result
unlet g:__result
return res
endfun
fun! Endoc_browse(arg0, arg1)
python <<EOF
r = plugin.doc_browse([vim.eval('a:arg0'), vim.eval('a:arg1')])
vim.command('let g:__result = ' + json.dumps(([] if r == None else r)))
EOF
let res = g:__result
unlet g:__result
return res
endfun
augroup Poi
    autocmd!
    autocmd VimLeave * call Enteardown('', '')
    autocmd BufWritePost * call Entype_check('', '')
    autocmd CursorMoved * call Enunqueue('', '')
augroup END
command! -nargs=0 EnNoTeardown call Endo_no_teardown('', '')
command! -nargs=0 EnTypeCheck call Entype_check_cmd('', '')
command! -nargs=0 EnType call Entype('', '')
command! -nargs=0 EnDocUri call Endoc_uri('', '')
command! -nargs=0 EnDocBrowse call Endoc_browse('', '')