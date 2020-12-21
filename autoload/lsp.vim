vim9script

# Vim LSP client

# Need Vim 8.2.2082 and higher
if v:version < 802 || !has('patch-8.2.2082')
  finish
endif

# LSP server information
var lspServers: list<dict<any>> = []

# filetype to LSP server map
var ftypeServerMap: dict<dict<any>> = {}

# List of diagnostics for each opened file
var diagsMap: dict<any> = {}

var lsp_log_dir: string = '/tmp/'

prop_type_add('LSPTextRef', {'highlight': 'Search'})
prop_type_add('LSPReadRef', {'highlight': 'DiffChange'})
prop_type_add('LSPWriteRef', {'highlight': 'DiffDelete'})

# Display a warning message
def WarnMsg(msg: string)
  :echohl WarningMsg
  :echomsg msg
  :echohl None
enddef

# Display an error message
def ErrMsg(msg: string)
  :echohl Error
  :echomsg msg
  :echohl None
enddef

# Return the LSP server for the given file type. Returns null dict if server
# is not found.
def LspGetServer(ftype: string): dict<any>
  return ftypeServerMap->get(ftype, {})
enddef

# Convert a LSP file URI to a Vim file name
def LspUriToFile(uri: string): string
  return uri[7:]
enddef

# Convert a Vim filenmae to an LSP URI
def LspFileToUri(fname: string): string
  return 'file://' .. fnamemodify(fname, ':p')
enddef

# process the 'initialize' method reply from the LSP server
def LSP_processInitializeReply(lspserver: dict<any>, req: dict<any>, reply: dict<any>): void
  if reply.result->len() <= 0
    return
  endif

  # interface 'InitializeResult'
  var caps: dict<any> = reply.result.capabilities
  lspserver.caps = caps

  # map characters that trigger signature help
  if caps->has_key('signatureHelpProvider')
    var triggers = caps.signatureHelpProvider.triggerCharacters
    for ch in triggers
      exe 'inoremap <buffer> <silent> ' .. ch .. ' ' .. ch .. "<C-R>=lsp#showSignature()<CR>"
    endfor
  endif

  # map characters that trigger insert mode completion
  if caps->has_key('completionProvider')
    var triggers = caps.completionProvider.triggerCharacters
    for ch in triggers
      exe 'inoremap <buffer> <silent> ' .. ch .. ' ' .. ch .. "<C-X><C-U>"
    endfor
  endif

  # send a "initialized" notification to server
  LSP_sendInitializedNotif(lspserver)
enddef

# process the 'textDocument/definition' / 'textDocument/declaration' /
# 'textDocument/typeDefinition' and 'textDocument/implementation' replies from
# the LSP server
def LSP_processDefDeclReply(lspserver: dict<any>, req: dict<any>, reply: dict<any>): void
  if reply.result->empty()
    WarnMsg("Error: definition is not found")
    return
  endif

  var result: dict<any> = reply.result[0]
  var file = LspUriToFile(result.uri)
  var wid = bufwinid(file)
  if wid != -1
    win_gotoid(wid)
  else
    exe 'split ' .. file
  endif
  # Set the previous cursor location mark
  setpos("'`", getcurpos())
  cursor(result.range.start.line + 1, result.range.start.character + 1)
  redraw!
enddef

# process the 'textDocument/signatureHelp' reply from the LSP server
def LSP_processSignaturehelpReply(lspserver: dict<any>, req: dict<any>, reply: dict<any>): void
  var result: dict<any> = reply.result
  if result.signatures->len() <= 0
    WarnMsg('No signature help available')
    return
  endif

  var sig: dict<any> = result.signatures[result.activeSignature]
  var text = sig.label
  var hllen = 0
  var startcol = 0
  if sig->has_key('parameters')
    var params_len = sig.parameters->len()
    if params_len > 0 && result.activeParameter < params_len
      var label = sig.parameters[result.activeParameter].label
      hllen = label->len()
      startcol = text->stridx(label)
    endif
  endif
  var popupID = popup_atcursor(text, {})
  prop_type_add('signature', {'bufnr': popupID->winbufnr(), 'highlight': 'Title'})
  if hllen > 0
    prop_add(1, startcol + 1, {'bufnr': popupID->winbufnr(), 'length': hllen, 'type': 'signature'})
  endif
enddef

def LSP_completeItemKindChar(kind: number): string
  var kindMap: list<string> = ['',
                    't', # Text
                    'm', # Method
                    'f', # Function
                    'C', # Constructor
                    'F', # Field
                    'v', # Variable
                    'c', # Class
                    'i', # Interface
                    'M', # Module
                    'p', # Property
                    'u', # Unit
                    'V', # Value
                    'e', # Enum
                    'k', # Keyword
                    'S', # Snippet
                    'C', # Color
                    'f', # File
                    'r', # Reference
                    'F', # Folder
                    'E', # EnumMember
                    'd', # Contant
                    's', # Struct
                    'E', # Event
                    'o', # Operator
                    'T'  # TypeParameter
                    ]
  if kind > 25
    return ''
  endif
  return kindMap[kind]
enddef

# process the 'textDocument/completion' reply from the LSP server
def LSP_processCompletionReply(lspserver: dict<any>, req: dict<any>, reply: dict<any>): void
  var items: list<dict<any>> = reply.result.items

  for item in items
    var d: dict<any> = {}
    if item->has_key('insertText')
      d.word = item.insertText
    elseif item->has_key('textEdit')
      d.word = item.textEdit.newText
    else
      continue
    endif
    if item->has_key('kind')
      # namespace CompletionItemKind
      # map LSP kind to complete-item-kind
      d.kind = LSP_completeItemKindChar(item.kind)
    endif
    if item->has_key('detail')
      d.menu = item.detail
    endif
    if item->has_key('documentation')
      d.info = item.documentation
    endif
    lspserver.completeItems->add(d)
  endfor

  lspserver.completePending = v:false
enddef

# process the 'textDocument/hover' reply from the LSP server
def LSP_processHoverReply(lspserver: dict<any>, req: dict<any>, reply: dict<any>): void
  if type(reply.result) == v:t_none
    return
  endif

  var hoverText: list<string>

  if type(reply.result.contents) == v:t_dict
    if reply.result.contents->has_key('kind')
      # MarkupContent
      if reply.result.contents.kind == 'plaintext'
        hoverText = reply.result.contents.value->split("\n")
      else
        ErrMsg('Error: Unsupported hover contents type (' .. reply.result.contents.kind .. ')')
        return
      endif
    elseif reply.result.contents->has_key('value')
      hoverText = reply.result.contents.value
    else
      ErrMsg('Error: Unsupported hover contents (' .. reply.result.contents .. ')')
      return
    endif
  elseif type(reply.result.contents) == v:t_list
    for e in reply.result.contents
      if type(e) == v:t_string
        hoverText->extend(e->split("\n"))
      else
        hoverText->extend(e.value->split("\n"))
      endif
    endfor
  elseif type(reply.result.contents) == v:t_string
    if reply.result.contents->empty()
      return
    endif
    hoverText->add(reply.result.contents)
  else
    ErrMsg('Error: Unsupported hover contents (' .. reply.result.contents .. ')')
    return
  endif
  hoverText->popup_atcursor({'moved': 'word'})
enddef

# process the 'textDocument/references' reply from the LSP server
def LSP_processReferencesReply(lspserver: dict<any>, req: dict<any>, reply: dict<any>): void
  if type(reply.result) == v:t_none || reply.result->empty()
    WarnMsg('Error: No references found')
    return
  endif

  # create a quickfix list with the location of the references
  var locations: list<dict<any>> = reply.result
  var qflist: list<dict<any>> = []
  for loc in locations
    var fname: string = LspUriToFile(loc.uri)
    var text: string = fname->getbufline(loc.range.start.line + 1)[0]
                                    ->trim("\t ", 1)
    qflist->add({'filename': fname,
                    'lnum': loc.range.start.line + 1,
                    'col': loc.range.start.character + 1,
                    'text': text})
  endfor
  setqflist([], ' ', {'title': 'Language Server', 'items': qflist})
  var save_winid = win_getid()
  copen
  win_gotoid(save_winid)
enddef

# process the 'textDocument/documentHighlight' reply from the LSP server
def LSP_processDocHighlightReply(lspserver: dict<any>, req: dict<any>, reply: dict<any>): void
  if reply.result->empty()
    return
  endif

  var fname: string = LspUriToFile(req.params.textDocument.uri)
  var bnum = bufnr(fname)

  for docHL in reply.result
    var kind: number = docHL->get('kind', 1)
    var propName: string
    if kind == 2
      # Read-access
      propName = 'LSPReadRef'
    elseif kind == 3
      # Write-access
      propName = 'LSPWriteRef'
    else
      # textual reference
      propName = 'LSPTextRef'
    endif
    prop_add(docHL.range.start.line + 1, docHL.range.start.character + 1,
               {'end_lnum': docHL.range.end.line + 1,
                'end_col': docHL.range.end.character + 1,
                'bufnr': bnum,
                'type': propName})
  endfor
enddef

# map the LSP symbol kind number to string
def LSP_symbolKindToName(symkind: number): string
  var symbolMap: list<string> = ['', 'File', 'Module', 'Namespace', 'Package',
	'Class', 'Method', 'Property', 'Field', 'Constructor', 'Enum',
        'Interface', 'Function', 'Variable', 'Constant', 'String', 'Number',
        'Boolean', 'Array', 'Object', 'Key', 'Null', 'EnumMember', 'Struct',
        'Event', 'Operator', 'TypeParameter']
  if symkind > 26
    return ''
  endif
  return symbolMap[symkind]
enddef

# jump to a symbol selected in the symbols window
def lsp#jumpToSymbol()
  var lnum: number = line('.') - 1
  if w:lsp_info.data[lnum]->empty()
    return
  endif

  var slnum: number = w:lsp_info.data[lnum].lnum
  var scol: number = w:lsp_info.data[lnum].col
  var wid: number = bufwinid(w:lsp_info.filename)
  if wid == -1
    :exe 'rightbelow vertical split ' .. w:lsp_info.filename
  else
    win_gotoid(wid)
  endif
  cursor(slnum, scol)
enddef

# process the 'textDocument/documentSymbol' reply from the LSP server
# Open a symbols window and display the symbols as a tree
def LSP_processDocSymbolReply(lspserver: dict<any>, req: dict<any>, reply: dict<any>): void
  if reply.result->empty()
    WarnMsg('No symbols are found')
    return
  endif

  var symbols: dict<list<dict<any>>>
  var symbolType: string

  var fname: string = LspUriToFile(req.params.textDocument.uri)
  for symbol in reply.result
    if symbol->has_key('location')
      symbolType = LSP_symbolKindToName(symbol.kind)
      if !symbols->has_key(symbolType)
        symbols[symbolType] = []
      endif
      var name: string = symbol.name
      if symbol->has_key('containerName')
        if symbol.containerName != ''
          name ..= ' [' .. symbol.containerName .. ']'
        endif
      endif
      symbols[symbolType]->add({'name': name,
                                'lnum': symbol.location.range.start.line + 1,
                                'col': symbol.location.range.start.character + 1})
    endif
  endfor

  var wid: number = bufwinid('LSP-Symbols')
  if wid == -1
    :20vnew LSP-Symbols
  else
    win_gotoid(wid)
  endif

  :setlocal modifiable
  :setlocal noreadonly
  :silent! :%d _
  :setlocal buftype=nofile
  :setlocal bufhidden=delete
  :setlocal noswapfile nobuflisted
  :setlocal nonumber norelativenumber fdc=0 nowrap winfixheight winfixwidth
  setline(1, ['# Language Server Symbols', '# ' .. fname])
  # First two lines in the buffer display comment information
  var lnumMap: list<dict<number>> = [{}, {}]
  var text: list<string> = []
  for [symType, syms] in items(symbols)
    text->extend(['', symType])
    lnumMap->extend([{}, {}])
    for s in syms
      text->add('  ' .. s.name)
      lnumMap->add({'lnum': s.lnum, 'col': s.col})
    endfor
  endfor
  append(line('$'), text)
  w:lsp_info = {'filename': fname, 'data': lnumMap}
  :nnoremap <silent> <buffer> q :quit<CR>
  :nnoremap <silent> <buffer> <CR> :call lsp#jumpToSymbol()<CR>
  :setlocal nomodifiable
enddef

# Process various reply messages from the LSP server
def LSP_processReply(lspserver: dict<any>, req: dict<any>, reply: dict<any>): void
  var lsp_reply_handlers: dict<func> =
    {
      'initialize': LSP_processInitializeReply,
      'textDocument/definition': LSP_processDefDeclReply,
      'textDocument/declaration': LSP_processDefDeclReply,
      'textDocument/typeDefinition': LSP_processDefDeclReply,
      'textDocument/implementation': LSP_processDefDeclReply,
      'textDocument/signatureHelp': LSP_processSignaturehelpReply,
      'textDocument/completion': LSP_processCompletionReply,
      'textDocument/hover': LSP_processHoverReply,
      'textDocument/references': LSP_processReferencesReply,
      'textDocument/documentHighlight': LSP_processDocHighlightReply,
      'textDocument/documentSymbol': LSP_processDocSymbolReply
    }

  if lsp_reply_handlers->has_key(req.method)
    lsp_reply_handlers[req.method](lspserver, req, reply)
  else
    ErrMsg("Error: Unsupported reply received from LSP server: " .. string(reply))
  endif
enddef

def LSP_processDiagNotif(lspserver: dict<any>, reply: dict<any>): void
  var fname: string = LspUriToFile(reply.params.uri)
  diagsMap->extend({[fname]: reply.params.diagnostics})
enddef

# process notification messages from the LSP server
def LSP_processNotif(lspserver: dict<any>, reply: dict<any>): void
  var lsp_notif_handlers: dict<func> =
    {
      'textDocument/publishDiagnostics': LSP_processDiagNotif
    }

  if lsp_notif_handlers->has_key(reply.method)
    lsp_notif_handlers[reply.method](lspserver, reply)
  else
    ErrMsg('Error: Unsupported notification received from LSP server ' .. string(reply))
  endif
enddef

# process a LSP server message
def LSP_processServerMsg(lspserver: dict<any>): void
  while lspserver.data->len() > 0
    var idx = stridx(lspserver.data, 'Content-Length: ')
    if idx == -1
      return
    endif

    var len = str2nr(lspserver.data[idx + 16:])
    if len == 0
      ErrMsg("Error: Content length is zero")
      return
    endif

    # Header and contents are separated by '\r\n\r\n'
    idx = stridx(lspserver.data, "\r\n\r\n")
    if idx == -1
      ErrMsg("Error: Content separator is not found")
      return
    endif

    idx = idx + 4

    if lspserver.data->len() - idx < len
      ErrMsg("Error: Didn't receive a complete message")
      return
    endif

    var content = lspserver.data[idx : idx + len - 1]
    var reply = content->json_decode()

    if reply->has_key('id')
      var req = lspserver.requests->get(string(reply.id))
      # Remove the corresponding stored request message
      lspserver.requests->remove(string(reply.id))

      if reply->has_key('error')
        var msg: string = reply.error.message
        if reply.error->has_key('data')
          msg = msg .. ', data = ' .. reply.error.message
        endif
        ErrMsg("Error: request " .. req.method .. " failed (" .. msg .. ")")
      else
        LSP_processReply(lspserver, req, reply)
      endif
    else
      LSP_processNotif(lspserver, reply)
    endif

    lspserver.data = lspserver.data[idx + len :]
  endwhile
enddef

def lsp#output_cb(lspserver: dict<any>, chan: channel, msg: string): void
  writefile(split(msg, "\n"), lsp_log_dir .. 'lsp_server.out', 'a')
  lspserver.data = lspserver.data .. msg
  LSP_processServerMsg(lspserver)
enddef

def lsp#error_cb(lspserver: dict<any>, chan: channel, emsg: string,): void
  writefile(split(emsg, "\n"), lsp_log_dir .. 'lsp_server.err', 'a')
enddef

def lsp#exit_cb(lspserver: dict<any>, job: job, status: number): void
  WarnMsg("LSP server exited with status " .. status)
enddef

# Return the next id for a LSP server request message
def LSP_nextReqID(lspserver: dict<any>): number
  var id = lspserver.nextID
  lspserver.nextID = id + 1
  return id
enddef

# Send a request message to LSP server
def LSP_sendToServer(lspserver: dict<any>, content: dict<any>): void
  var req_js: string = content->json_encode()
  var msg = "Content-Length: " .. req_js->len() .. "\r\n\r\n"
  var ch = lspserver.job->job_getchannel()
  ch->ch_sendraw(msg)
  ch->ch_sendraw(req_js)
enddef

def LSP_createReqMsg(lspserver: dict<any>, method: string): dict<any>
  var req = {}
  req.jsonrpc = '2.0'
  req.id = LSP_nextReqID(lspserver)
  req.method = method
  req.params = {}

  # Save the request, so that the corresponding response can be processed
  lspserver.requests->extend({[string(req.id)]: req})

  return req
enddef

def LSP_createNotifMsg(notif: string): dict<any>
  var req = {}
  req.jsonrpc = '2.0'
  req.method = notif
  req.params = {}

  return req
enddef

# Send a "initialize" LSP request
def LSP_initServer(lspserver: dict<any>)
  var req = LSP_createReqMsg(lspserver, 'initialize')

  # interface 'InitializeParams'
  var initparams: dict<any> = {}
  initparams.processId = getpid()
  initparams.clientInfo = {'name': 'Vim', 'version': string(v:versionlong)}
  req.params->extend(initparams)

  LSP_sendToServer(lspserver, req)
enddef

# Send a "initialized" LSP notification
def LSP_sendInitializedNotif(lspserver: dict<any>)
  var notif: dict<any> = LSP_createNotifMsg('initialized')
  LSP_sendToServer(lspserver, notif)
enddef

# Start a LSP server
def LSP_startServer(lspserver: dict<any>): number
  if lspserver.running
    WarnMsg("LSP server for is already running")
    return 0
  endif

  var cmd = [lspserver.path]
  cmd->extend(lspserver.args)

  var opts = {'in_mode': 'raw',
              'out_mode': 'raw',
              'err_mode': 'raw',
              'noblock': 1,
              'out_cb': function('lsp#output_cb', [lspserver]),
              'err_cb': function('lsp#error_cb', [lspserver]),
              'exit_cb': function('lsp#exit_cb', [lspserver])}

  writefile([], lsp_log_dir .. 'lsp_server.out')
  writefile([], lsp_log_dir .. 'lsp_server.err')
  lspserver.data = ''
  lspserver.caps = {}
  lspserver.nextID = 1
  lspserver.requests = {}
  lspserver.completePending = v:false

  var job = job_start(cmd, opts)
  if job->job_status() == 'fail'
    ErrMsg("Error: Failed to start LSP server " .. lspserver.path)
    return 1
  endif

  # wait for the LSP server to start
  sleep 10m

  lspserver.job = job
  lspserver.running = v:true

  LSP_initServer(lspserver)

  return 0
enddef

# Send a 'shutdown' request to the LSP server
def LSP_shutdownServer(lspserver: dict<any>): void
  var req = LSP_createReqMsg(lspserver, 'shutdown')
  LSP_sendToServer(lspserver, req)
enddef

# Send a 'exit' notification to the LSP server
def LSP_exitServer(lspserver: dict<any>): void
  var notif: dict<any> = LSP_createNotifMsg('exit')
  LSP_sendToServer(lspserver, notif)
enddef

# Stop a LSP server
def LSP_stopServer(lspserver: dict<any>): number
  if !lspserver.running
    WarnMsg("LSP server is not running")
    return 0
  endif

  LSP_shutdownServer(lspserver)

  # Wait for the server to process the shutodwn request
  sleep 1

  LSP_exitServer(lspserver)

  lspserver.job->job_stop()
  lspserver.job = v:none
  lspserver.running = v:false
  lspserver.requests = {}
  return 0
enddef

# Send a LSP "textDocument/didOpen" notification
def LSP_textdocDidOpen(lspserver: dict<any>, bnum: number, ftype: string): void
  var notif: dict<any> = LSP_createNotifMsg('textDocument/didOpen')

  # interface DidOpenTextDocumentParams
  # interface TextDocumentItem
  var tdi = {}
  tdi.uri = LspFileToUri(bufname(bnum))
  tdi.languageId = ftype
  tdi.version = 1
  tdi.text = getbufline(bnum, 1, '$')->join("\n") .. "\n"
  notif.params->extend({'textDocument': tdi})

  LSP_sendToServer(lspserver, notif)
enddef

# Send a LSP "textDocument/didClose" notification
def LSP_textdocDidClose(lspserver: dict<any>, fname: string): void
  var notif: dict<any> = LSP_createNotifMsg('textDocument/didClose')

  # interface DidCloseTextDocumentParams
  #   interface TextDocumentIdentifier
  var tdid = {}
  tdid.uri = LspFileToUri(fname)
  notif.params->extend({'textDocument': tdid})

  LSP_sendToServer(lspserver, notif)
enddef

# Goto a definition using "textDocument/definition" LSP request
def lsp#gotoDefinition()
  var ftype: string = &filetype
  if ftype == ''
    return
  endif

  var lspserver: dict<any> = LspGetServer(ftype)
  if lspserver->empty()
    ErrMsg('Error: LSP server for "' .. ftype .. '" filetype is not found')
    return
  endif
  if !lspserver.running
    ErrMsg('Error: LSP server for "' .. ftype .. '" filetype is not running')
    return
  endif
  # Check whether LSP server supports jumping to a definition
  if !lspserver.caps->has_key('definitionProvider')
              || !lspserver.caps.definitionProvider
    ErrMsg("Error: LSP server does not support jumping to a definition")
    return
  endif

  var fname: string = @%
  if fname == ''
    return
  endif

  var lnum: number = line('.') - 1
  var col: number = col('.') - 1

  var req = LSP_createReqMsg(lspserver, 'textDocument/definition')

  # interface DefinitionParams
  # interface TextDocumentPositionParams
  # interface TextDocumentIdentifier
  req.params->extend({'textDocument': {'uri': LspFileToUri(fname)}})
  # interface Position
  req.params->extend({'position': {'line': lnum, 'character': col}})

  LSP_sendToServer(lspserver, req)
enddef

# Goto a declaration using "textDocument/declaration" LSP request
def lsp#gotoDeclaration()
  var ftype: string = &filetype
  if ftype == ''
    return
  endif

  var lspserver: dict<any> = LspGetServer(ftype)
  if lspserver->empty()
    ErrMsg('Error: LSP server for "' .. ftype .. '" filetype is not found')
    return
  endif
  if !lspserver.running
    ErrMsg('Error: LSP server for "' .. ftype .. '" filetype is not running')
    return
  endif
  # Check whether LSP server supports jumping to a declaration
  if !lspserver.caps->has_key('declarationProvider')
              || !lspserver.caps.declarationProvider
    ErrMsg("Error: LSP server does not support jumping to a declaration")
    return
  endif

  var fname: string = @%
  if fname == ''
    return
  endif

  var lnum: number = line('.') - 1
  var col: number = col('.') - 1

  var req = LSP_createReqMsg(lspserver, 'textDocument/declaration')

  # interface DeclarationParams
  #   interface TextDocumentPositionParams
  #     interface TextDocumentIdentifier
  req.params->extend({'textDocument': {'uri': LspFileToUri(fname)}})
  #     interface Position
  req.params->extend({'position': {'line': lnum, 'character': col}})

  LSP_sendToServer(lspserver, req)
enddef

# Go to a type definition using "textDocument/typeDefinition" LSP request
def lsp#gotoTypedef()
  var ftype: string = &filetype
  if ftype == ''
    return
  endif

  var lspserver: dict<any> = LspGetServer(ftype)
  if lspserver->empty()
    ErrMsg('Error: LSP server for "' .. ftype .. '" filetype is not found')
    return
  endif
  if !lspserver.running
    ErrMsg('Error: LSP server for "' .. ftype .. '" filetype is not running')
    return
  endif
  # Check whether LSP server supports jumping to a type definition
  if !lspserver.caps->has_key('typeDefinitionProvider')
              || !lspserver.caps.typeDefinitionProvider
    ErrMsg("Error: LSP server does not support jumping to a type definition")
    return
  endif

  var fname: string = @%
  if fname == ''
    return
  endif

  var lnum: number = line('.') - 1
  var col: number = col('.') - 1

  var req = LSP_createReqMsg(lspserver, 'textDocument/typeDefinition')

  # interface TypeDefinitionParams
  #   interface TextDocumentPositionParams
  #     interface TextDocumentIdentifier
  req.params->extend({'textDocument': {'uri': LspFileToUri(fname)}})
  #     interface Position
  req.params->extend({'position': {'line': lnum, 'character': col}})

  LSP_sendToServer(lspserver, req)
enddef

# Go to a implementation using "textDocument/implementation" LSP request
def lsp#gotoImplementation()
  var ftype: string = &filetype
  if ftype == ''
    return
  endif

  var lspserver: dict<any> = LspGetServer(ftype)
  if lspserver->empty()
    ErrMsg('Error: LSP server for "' .. ftype .. '" filetype is not found')
    return
  endif
  if !lspserver.running
    ErrMsg('Error: LSP server for "' .. ftype .. '" filetype is not running')
    return
  endif
  # Check whether LSP server supports jumping to a type definition
  if !lspserver.caps->has_key('implementationProvider')
              || !lspserver.caps.implementationProvider
    ErrMsg("Error: LSP server does not support jumping to an implementation")
    return
  endif

  var fname: string = @%
  if fname == ''
    return
  endif

  var lnum: number = line('.') - 1
  var col: number = col('.') - 1

  var req = LSP_createReqMsg(lspserver, 'textDocument/implementation')

  # interface ImplementationParams
  #   interface TextDocumentPositionParams
  #     interface TextDocumentIdentifier
  req.params->extend({'textDocument': {'uri': LspFileToUri(fname)}})
  #     interface Position
  req.params->extend({'position': {'line': lnum, 'character': col}})

  LSP_sendToServer(lspserver, req)
enddef

# Show the signature using "textDocument/signatureHelp" LSP method
# Invoked from an insert-mode mapping, so return an empty string.
def lsp#showSignature(): string
  var ftype: string = &filetype
  if ftype == ''
    return ''
  endif

  var lspserver: dict<any> = LspGetServer(ftype)
  if lspserver->empty()
    ErrMsg('Error: LSP server for "' .. ftype .. '" filetype is not found')
    return ''
  endif
  if !lspserver.running
    ErrMsg('Error: LSP server for "' .. ftype .. '" filetype is not running')
    return ''
  endif
  # Check whether LSP server supports signature help
  if !lspserver.caps->has_key('signatureHelpProvider')
    ErrMsg("Error: LSP server does not support signature help")
    return ''
  endif

  var fname: string = @%
  if fname == ''
    return ''
  endif

  # first send all the changes in the current buffer to the LSP server
  listener_flush()

  var lnum: number = line('.') - 1
  var col: number = col('.') - 1

  var req = LSP_createReqMsg(lspserver, 'textDocument/signatureHelp')
  # interface SignatureHelpParams
  #   interface TextDocumentPositionParams
  #     interface TextDocumentIdentifier
  req.params->extend({'textDocument': {'uri': LspFileToUri(fname)}})
  #     interface Position
  req.params->extend({'position': {'line': lnum, 'character': col}})

  LSP_sendToServer(lspserver, req)
  return ''
enddef

# buffer change notification listener
def lsp#bufchange_listener(bnum: number, start: number, end: number, added: number, changes: list<dict<number>>)
  var ftype = getbufvar(bnum, '&filetype')
  var lspserver: dict<any> = LspGetServer(ftype)
  if lspserver->empty() || !lspserver.running
    return
  endif

  var notif: dict<any> = LSP_createNotifMsg('textDocument/didChange')

  # interface DidChangeTextDocumentParams
  #   interface VersionedTextDocumentIdentifier
  var vtdid: dict<any> = {}
  vtdid.uri = LspFileToUri(bufname(bnum))
  # Use Vim 'changedtick' as the LSP document version number
  vtdid.version = getbufvar(bnum, 'changedtick')
  notif.params->extend({'textDocument': vtdid})
  #   interface TextDocumentContentChangeEvent
  var changeset: list<dict<any>>

  ##### FIXME: Sending specific buffer changes to the LSP server doesn't
  ##### work properly as the computed line range numbers is not correct.
  ##### For now, send the entire content of the buffer to LSP server.
  # #     Range
  # for change in changes
  #   var lines: string
  #   var start_lnum: number
  #   var end_lnum: number
  #   var start_col: number
  #   var end_col: number
  #   if change.added == 0
  #     # lines changed
  #     start_lnum =  change.lnum - 1
  #     end_lnum = change.end - 1
  #     lines = getbufline(bnum, change.lnum, change.end - 1)->join("\n") .. "\n"
  #     start_col = 0
  #     end_col = 0
  #   elseif change.added > 0
  #     # lines added
  #     start_lnum = change.lnum - 1
  #     end_lnum = change.lnum - 1
  #     start_col = 0
  #     end_col = 0
  #     lines = getbufline(bnum, change.lnum, change.lnum + change.added - 1)->join("\n") .. "\n"
  #   else
  #     # lines removed
  #     start_lnum = change.lnum - 1
  #     end_lnum = change.lnum + (-change.added) - 1
  #     start_col = 0
  #     end_col = 0
  #     lines = ''
  #   endif
  #   var range: dict<dict<number>> = {'start': {'line': start_lnum, 'character': start_col}, 'end': {'line': end_lnum, 'character': end_col}}
  #   changeset->add({'range': range, 'text': lines})
  # endfor
  changeset->add({'text': getbufline(bnum, 1, '$')->join("\n") .. "\n"})
  notif.params->extend({'contentChanges': changeset})

  LSP_sendToServer(lspserver, notif)
enddef

# A new buffer is opened. If LSP is supported for this buffer, then add it
def lsp#addFile(bnum: number, ftype: string): void
  if ftype == ''
    return
  endif
  var lspserver: dict<any> = LspGetServer(ftype)
  if lspserver->empty()
    return
  endif
  if !lspserver.running
    LSP_startServer(lspserver)
  endif
  LSP_textdocDidOpen(lspserver, bnum, ftype)

  # Display hover information
  autocmd CursorHold <buffer> call LSP_hover()

  # add a listener to track changes to this buffer
  listener_add(function('lsp#bufchange_listener'), bnum)
  setbufvar(bnum, '&completefunc', 'lsp#completeFunc')
  setbufvar(bnum, '&completeopt', 'menuone,preview,noinsert')
enddef

def lsp#removeFile(fname: string, ftype: string): void
  if fname == '' || ftype == ''
    return
  endif
  var lspserver: dict<any> = LspGetServer(ftype)
  if lspserver->empty() || !lspserver.running
    return
  endif
  LSP_textdocDidClose(lspserver, fname)
  if diagsMap->has_key(fname)
    diagsMap->remove(fname)
  endif
enddef

def lsp#stopAllServers()
  for lspserver in lspServers
    if lspserver.running
      LSP_stopServer(lspserver)
    endif
  endfor
enddef

# Register a LSP server for one or more file types
def lsp#addServer(serverList: list<dict<any>>)
  for server in serverList
    if !server->has_key('filetype') || !server->has_key('path') || !server->has_key('args')
      ErrMsg('Error: LSP server information is missing filetype or path or args')
      continue
    endif

    if !file_readable(server.path)
      ErrMsg('Error: LSP server ' .. server.path .. ' is not found')
      return
    endif
    if type(server.args) != v:t_list
      ErrMsg('Error: Arguments for LSP server ' .. server.path .. ' is not a List')
      return
    endif

    var lspserver: dict<any> = {
      path: server.path,
      args: server.args,
      running: v:false,
      job: v:none,
      data: '',
      nextID: 1,
      caps: {},
      requests: {},
      completePending: v:false
    }

    if type(server.filetype) == v:t_string
      ftypeServerMap->extend({[server.filetype]: lspserver})
    elseif type(server.filetype) == v:t_list
      for ftype in server.filetype
        ftypeServerMap->extend({[ftype]: lspserver})
      endfor
    else
      ErrMsg('Error: Unsupported file type information "' .. string(server.filetype)
                                  .. '" in LSP server registration')
      continue
    endif
  endfor
enddef

def lsp#showServers()
  for [ftype, lspserver] in items(ftypeServerMap)
    var msg = ftype .. "    "
    if lspserver.running
      msg ..= 'running'
    else
      msg ..= 'not running'
    endif
    msg ..= '    ' .. lspserver.path
    echomsg msg
  endfor
enddef

# Map the LSP DiagnosticSeverity to a type character
def LSPdiagSevToType(severity: number): string
  var typeMap: list<string> = ['E', 'W', 'I', 'N']

  if severity > 4
    return ''
  endif

  return typeMap[severity - 1]
enddef

# Display the diagnostic messages from the LSP server for the current buffer
def lsp#showDiagnostics(): void
  var fname: string = expand('%:p')
  if fname == ''
    return
  endif

  if !diagsMap->has_key(fname) || diagsMap[fname]->empty()
    WarnMsg('No diagnostic messages found for ' .. fname)
    return
  endif

  var qflist: list<dict<any>> = []
  var text: string

  for diag in diagsMap[fname]
    text = diag.message->substitute("\n\\+", "\n", 'g')
    qflist->add({'filename': fname,
                    'lnum': diag.range.start.line + 1,
                    'col': diag.range.start.character + 1,
                    'text': text,
                    'type': LSPdiagSevToType(diag.severity)})
  endfor
  setqflist([], ' ', {'title': 'Language Server Diagnostics', 'items': qflist})
  :copen
enddef

def LSP_getCompletion(lspserver: dict<any>): void
  # Check whether LSP server supports completion
  if !lspserver.caps->has_key('completionProvider')
    ErrMsg("Error: LSP server does not support completion")
    return
  endif

  var fname = @%
  if fname == ''
    return
  endif

  var lnum = line('.') - 1
  var col = col('.') - 1

  var req = LSP_createReqMsg(lspserver, 'textDocument/completion')

  # interface CompletionParams
  # interface TextDocumentPositionParams
  # interface TextDocumentIdentifier
  req.params->extend({'textDocument': {'uri': LspFileToUri(fname)}})
  # interface Position
  req.params->extend({'position': {'line': lnum, 'character': col}})

  LSP_sendToServer(lspserver, req)
enddef

# Insert mode completion handler
def lsp#completeFunc(findstart: number, base: string): any
  var ftype: string = &filetype
  var lspserver: dict<any> = LspGetServer(ftype)

  if findstart
    if lspserver->empty()
      ErrMsg('Error: LSP server for "' .. ftype .. '" filetype is not found')
      return -2
    endif
    if !lspserver.running
      ErrMsg('Error: LSP server for "' .. ftype .. '" filetype is not running')
      return -2
    endif

    # first send all the changes in the current buffer to the LSP server
    listener_flush()

    lspserver.completePending = v:true
    lspserver.completeItems = []
    # initiate a request to LSP server to get list of completions
    LSP_getCompletion(lspserver)

    # locate the start of the word
    var line = getline('.')
    var start = col('.') - 1
    while start > 0 && line[start - 1] =~ '\k'
      start -= 1
    endwhile
    return start
  else
    var count: number = 0
    while !complete_check() && lspserver.completePending
            && count < 500
      sleep 2m
      count += 1
    endwhile

    var res: list<dict<any>> = []
    for item in lspserver.completeItems
      res->add(item)
    endfor
    return res
  endif
enddef

def LSP_hover()
  var ftype = &filetype
  if ftype == ''
    return
  endif

  var lspserver: dict<any> = LspGetServer(ftype)
  if lspserver->empty()
    ErrMsg('Error: LSP server for "' .. ftype .. '" filetype is not found')
    return
  endif
  if !lspserver.running
    ErrMsg('Error: LSP server for "' .. ftype .. '" filetype is not running')
    return
  endif
  # Check whether LSP server supports getting hover information
  if !lspserver.caps->has_key('hoverProvider')
              || !lspserver.caps.hoverProvider
    return
  endif

  var fname = @%
  if fname == ''
    return
  endif
  var lnum = line('.') - 1
  var col = col('.') - 1

  var req = LSP_createReqMsg(lspserver, 'textDocument/hover')
  # interface HoverParams
  # interface TextDocumentPositionParams
  # interface TextDocumentIdentifier
  req.params->extend({'textDocument': {'uri': LspFileToUri(fname)}})
  # interface Position
  req.params->extend({'position': {'line': lnum, 'character': col}})

  LSP_sendToServer(lspserver, req)
enddef

def lsp#showReferences()
  var ftype = &filetype
  if ftype == ''
    return
  endif

  var lspserver: dict<any> = LspGetServer(ftype)
  if lspserver->empty()
    ErrMsg('Error: LSP server for "' .. ftype .. '" filetype is not found')
    return
  endif
  if !lspserver.running
    ErrMsg('Error: LSP server for "' .. ftype .. '" filetype is not running')
    return
  endif

  # Check whether LSP server supports getting reference information
  if !lspserver.caps->has_key('referencesProvider')
              || !lspserver.caps.referencesProvider
    ErrMsg("Error: LSP server does not support showing references")
    return
  endif

  var fname = @%
  if fname == ''
    return
  endif
  var lnum = line('.') - 1
  var col = col('.') - 1

  var req = LSP_createReqMsg(lspserver, 'textDocument/references')
  # interface ReferenceParams
  # interface TextDocumentPositionParams
  # interface TextDocumentIdentifier
  req.params->extend({'textDocument': {'uri': LspFileToUri(fname)}})
  # interface Position
  req.params->extend({'position': {'line': lnum, 'character': col}})
  req.params->extend({'context': {'includeDeclaration': v:true}})

  LSP_sendToServer(lspserver, req)
enddef

def lsp#docHighlight()
  var ftype = &filetype
  if ftype == ''
    return
  endif

  var lspserver: dict<any> = LspGetServer(ftype)
  if lspserver->empty()
    ErrMsg('Error: LSP server for "' .. ftype .. '" filetype is not found')
    return
  endif
  if !lspserver.running
    ErrMsg('Error: LSP server for "' .. ftype .. '" filetype is not running')
    return
  endif

  # Check whether LSP server supports getting reference information
  if !lspserver.caps->has_key('documentHighlightProvider')
              || !lspserver.caps.documentHighlightProvider
    ErrMsg("Error: LSP server does not support document highlight")
    return
  endif

  var fname = @%
  if fname == ''
    return
  endif
  var lnum = line('.') - 1
  var col = col('.') - 1

  var req = LSP_createReqMsg(lspserver, 'textDocument/documentHighlight')
  # interface DocumentHighlightParams
  # interface TextDocumentPositionParams
  # interface TextDocumentIdentifier
  req.params->extend({'textDocument': {'uri': LspFileToUri(fname)}})
  # interface Position
  req.params->extend({'position': {'line': lnum, 'character': col}})

  LSP_sendToServer(lspserver, req)
enddef

def lsp#docHighlightClear()
  prop_remove({'type': 'LSPTextRef', 'all': v:true}, 1, line('$'))
  prop_remove({'type': 'LSPReadRef', 'all': v:true}, 1, line('$'))
  prop_remove({'type': 'LSPWriteRef', 'all': v:true}, 1, line('$'))
enddef

def lsp#showDocSymbols()
  var ftype = &filetype
  if ftype == ''
    return
  endif

  var lspserver: dict<any> = LspGetServer(ftype)
  if lspserver->empty()
    ErrMsg('Error: LSP server for "' .. ftype .. '" filetype is not found')
    return
  endif
  if !lspserver.running
    ErrMsg('Error: LSP server for "' .. ftype .. '" filetype is not running')
    return
  endif

  # Check whether LSP server supports getting reference information
  if !lspserver.caps->has_key('documentSymbolProvider')
              || !lspserver.caps.documentSymbolProvider
    ErrMsg("Error: LSP server does not support getting list of symbols")
    return
  endif

  var fname = @%
  if fname == ''
    return
  endif

  var req = LSP_createReqMsg(lspserver, 'textDocument/documentSymbol')
  # interface DocumentSymbolParams
  # interface TextDocumentIdentifier
  req.params->extend({'textDocument': {'uri': LspFileToUri(fname)}})

  LSP_sendToServer(lspserver, req)
enddef

# vim: shiftwidth=2 sts=2 expandtab
