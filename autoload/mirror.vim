"=============================================================================
" FILE: mirror.vim
" AUTHOR:  Alexander Tsygankov <capybarov@gmail.com>
" License: MIT {{{
"     Permission is hereby granted, free of charge, to any person obtaining
"     a copy of this software and associated documentation files (the
"     "Software"), to deal in the Software without restriction, including
"     without limitation the rights to use, copy, modify, merge, publish,
"     distribute, sublicense, and/or sell copies of the Software, and to
"     permit persons to whom the Software is furnished to do so, subject to
"     the following conditions:
"
"     The above copyright notice and this permission notice shall be included
"     in all copies or substantial portions of the Software.
"
"     THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
"     OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
"     MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
"     IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
"     CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
"     TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
"     SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
" }}}
"=============================================================================

if exists('g:autoloaded_mirror')
  finish
endif
let g:autoloaded_mirror = 1

let g:mirror#config_path = expand(get(g:, 'mirror#config_path', '~/.mirrors'))
let g:mirror#open_with = get(g:, 'mirror#open_with', 'Explore')
let g:mirror#diff_layout = get(g:, 'mirror#diff_layout', 'vsplit')
let g:mirror#ssh_auto_cd = get(g:, 'mirror#ssh_auto_cd', 1)
let g:mirror#ssh_shell = get(g:, 'mirror#ssh_shell', '$SHELL --login')
let g:mirror#cache_dir = expand(get(g:, 'mirror#cache_dir', '~/.cache/mirror.vim'))
let g:mirror#spawn_command = '!'
let g:netrw_silent = get(g:, 'netrw_silent', 1)

let g:mirror#config = {}
let g:mirror#local_default_environments = {}
let g:mirror#global_default_environments = {}

" Parse line like 'environment: remote_path'
function! s:GetEnvironmentAndPath(line)
  let m = matchlist(a:line, '\s*\(\S\+\):\s*\(.*\)\s*$')
  let [environment, remote_path] = [m[1], m[2]]
  let remote_path = substitute(remote_path, '/$', '', '')
  return [environment, remote_path]
endfunction

" Parse lines from mirrors config, return dictionary
function! s:ParseMirrors(list)
  let result = {}
  let current_node = ''
  for line in a:list
    if empty(line) || match(line, '\s\*#') != -1
      continue
    endif
    " extract project
    if match(line, '^\s\+') == -1
      let current_node = substitute(line, ':$', '', '')
      " expand glob
      if match(current_node, '*') != -1
        let dirs = filter(split(expand(current_node), '\n'), 'isdirectory(v:val)')
        " create new project path for each directory in expanded glob
        for dir in dirs
          let result[dir] = {}
        endfor
      " nothing to expand, save new project path
      else
        let result[expand(current_node)] = {}
      endif
    " extract environment and remote_path
    else
      let wildcard_index = match(current_node, '*')
      " expand and save remote path for each directory in expanded project path
      if wildcard_index != -1
        let dirs = filter(split(expand(current_node), '\n'), 'isdirectory(v:val)')
        for dir in dirs
          let wildcard_path = strpart(dir, wildcard_index)
          " replace wildcards in remote_path with its actually contents from project path
          let expanded_line = substitute(line, '*', wildcard_path, 'g')
          let [env, remote_path] = s:GetEnvironmentAndPath(expanded_line)
          let result[dir][env] = remote_path
        endfor
      " nothing to expand, just save remote_path as is
      else
        let [env, remote_path] = s:GetEnvironmentAndPath(line)
        let result[expand(current_node)][env] = remote_path
      endif
    endif
  endfor
  return result
endfunction

" Read mirrors config into memory
function! mirror#ReadConfig()
  if filereadable(g:mirror#config_path)
    let g:mirror#config = s:ParseMirrors(readfile(g:mirror#config_path))
  endif
  return g:mirror#config
endfunction

" Read cache file into memory
function! mirror#ReadCache()
  let path = g:mirror#cache_dir . '/default_environments'
  if filereadable(path)
    let default_environments = eval(readfile(path)[0])
    if type(default_environments) ==# type({})
      let g:mirror#global_default_environments = default_environments
    endif
  endif
endfunction

" Save global environment sessions into cache file
function! s:UpdateCache()
  if !isdirectory(g:mirror#cache_dir)
    call mkdir(g:mirror#cache_dir, 'p')
  endif
  call writefile(
        \ [string(g:mirror#global_default_environments)],
        \ g:mirror#cache_dir . '/default_environments'
        \ )
endfunction

" Add scp:// to given string
function! s:PrependProtocol(string)
  if stridx(a:string, 'scp://') == -1
    return 'scp://' . a:string
  endif
  return a:string
endfunction

" Extract host, port and path from remote_path
function! s:ParseRemotePath(remote_path)
  " scp://host:port/path
  let m = matchlist(a:remote_path, '^scp://\(.\{-}\)\%(:\(\d\+\)\)\?/\(.\+\)$')
  let host = m[1]
  let port = m[2]
  let path = m[3]
  return [host, port, path]
endfunction

" Build scp command from args
function! s:ScpCommand(port, src_path, dest_path)
  let port = empty(a:port) ? '' : '-P ' . a:port
  return printf('scp %s -q %s %s', port, a:src_path, a:dest_path)
endfunction

" Build ssh command from args
function! s:SSHCommand(host, port)
  let port = empty(a:port) ? '' : '-p ' . a:port
  return printf('ssh -q %s %s', port, a:host)
endfunction

" Find port, local_file and remote_file for current environment
function! s:PrepareToCopy(env)
  let [local_path, remote_path] = s:FindPaths(a:env)
  let [host, port, path] = s:ParseRemotePath(remote_path . local_path)
  let remote_file = printf('%s:%s', host, path)
  let local_file = expand('%:p')
  return [port, local_file, remote_file]
endfunction

" Find local path of current file and remote path for current project
function! s:FindPaths(env)
  " example:
  " b:project_with_mirror: /home/user/work/project
  " local_path: /home/user/work/project/config/database.yml
  "           m[1]                   m[2]
  " (/home/user/work/project)(/config/database.yml)
  let local_path = expand('%:p')
  let m = matchlist(local_path, '\(' . b:project_with_mirror . '\)\(.*\)')
  let local_path = substitute(m[2], '^/', '', '')

  let remote_path = s:PrependProtocol(get(s:CurrentMirrors(), a:env))
  if match(remote_path, '/$') < 0
    let remote_path .= '/'
  endif
  return [local_path, remote_path]
endfunction

" Open file via scp for given env
function! s:OpenFile(env, command)
  let [local_path, remote_path] = s:FindPaths(a:env)
  let full_path = remote_path . local_path
  execute ':' . a:command full_path
  redraw!
endfunction

" Find buffer that starts with 'scp://' and delete it
function! mirror#CloseRemoteBuffer()
  execute ':bdelete' bufnr('^scp://')
endfunction

" Open diff with remote file for given env
function! s:OpenDiff(env, command)
  diffthis
  call s:OpenFile(a:env, a:command)
  diffthis
endfunction

" Open remote project directory for given env
function! s:OpenProjectDir(env, command)
  let [_, remote_path] = s:FindPaths(a:env)
  execute ':' . a:command remote_path
endfunction

" Open remote parent directory of currently opened file for given env
function! s:OpenParentDir(env, command)
  let [local_path, remote_path] = s:FindPaths(a:env)
  let parent_directory = fnamemodify(local_path, ':h')
  " parent directory is empty
  if parent_directory ==# '.'
    let parent_directory = ''
  else
    " required for netrw
    let parent_directory .= '/'
  endif
  execute ':' . a:command remote_path . parent_directory
endfunction

" Open remote system root directory of for given env
function! s:OpenRootDir(env, command)
  let [_, remote_path] = s:FindPaths(a:env)
  let [host, _, _] = s:ParseRemotePath(remote_path)
  execute ':' . a:command printf('scp://%s//', host)
endfunction

" Neovim async job handler
function s:JobHandler(job_id, data, event) dict abort
  if a:event == 'stderr'
    " Saving error message
    if !has_key(self, 'stderr')
      let self.stderr = ''
    end
    let self.stderr .= join(a:data, '')
  elseif a:event == 'exit'
    " Success exit
    if a:data == 0
      if self.type == 'MirrorPull'
        " Reload the local file that was just updated
        let current_buffer = bufnr('%')
        execute 'buffer ' . self.buffer_number
        edit!
        " Go back to the file we edited
        if current_buffer != self.buffer_number
          execute 'buffer ' . current_buffer
        end
      end
      echo self.message
    " Process exited with error
    else
      redraw!
      let message = self.type . ' failed'
      if has_key(self, 'stderr')
        let message .= ' "' . self.stderr . '"'
      end
      echo message
    end
  end
endfunction

let s:callbacks = {
      \ 'on_stdout': function('s:JobHandler'),
      \ 'on_stderr': function('s:JobHandler'),
      \ 'on_exit': function('s:JobHandler')
      \ }

" Executing commands asynchronously or synchronously
function! s:ExecuteCommand(type, command, message)
  if has('nvim')
    let job_args = extend({
          \ 'type': a:type,
          \ 'message': a:message,
          \ 'buffer_number': bufnr('%')
          \ }, s:callbacks)
    call jobstart(a:command, job_args)
  else
    execute g:mirror#spawn_command . a:command
    if !v:shell_error
      " Reload the local file that was just updated
      if a:type == 'MirrorPull'
        edit!
      end
      echo a:message
    endif
  endif
endfunction

" Overwrite remote file with currently opened file
function! s:PushFile(env)
  let [port, local_file, remote_file, local_dir, remote_dir] = s:PrepareToRsync(a:env)
  "let [port, local_file, remote_file] = s:PrepareToCopy(a:env)
  let command = s:RsyncCommand(port, local_file, remote_file, remote_dir, 1)
  "let command = s:ScpCommand(port, local_file, remote_file)
  let message = 'Pushed to ' . remote_file
  call s:ExecuteCommand('MirrorPush', command, message)
endfunction

" Overwrite local file by remote_file
function! s:PullFile(env)
  let [port, local_file, remote_file] = s:PrepareToCopy(a:env)
  let command = s:ScpCommand(port, remote_file, local_file)
  let message = 'Pulled from ' . remote_file
  call s:ExecuteCommand('MirrorPull', command, message)
endfunction

" Establish ssh connection with remote host
function! s:SSHConnection(env)
  let [_, remote_path] = s:FindPaths(a:env)
  let [host, port, path] = s:ParseRemotePath(remote_path)
  let ssh_command = s:SSHCommand(host, port)
  if g:mirror#ssh_auto_cd
    " change directory to remote project path and start shell
    let ssh_command .= printf(" -t 'cd %s && %s'", path, g:mirror#ssh_shell)
  endif
  " example: ssh -p 23 user@host -t 'cd my_project && $SHELL --login'
  if has('nvim')
    execute 'tabnew | terminal ' . ssh_command
  else
    execute g:mirror#spawn_command . ssh_command
  endif
endfunction

" Get information about remote file by executing ls -lh
" -rw-rw-r-- 1 user user 7.2K Jun 23 20:51 path/to/file
function! s:GetFileInfo(env)
  let [local_path, remote_path] = s:FindPaths(a:env)
  let [host, port, path] = s:ParseRemotePath(remote_path . local_path)
  execute g:mirror#spawn_command . s:SSHCommand(host, port) 'ls -lh' path
endfunction

" Open mirrors config in split
function! mirror#EditConfig()
  execute ':botright split' g:mirror#config_path
  nnoremap <buffer> <silent> q :<C-U>bdelete<CR>
  setlocal filetype=yaml
endfunction

" Set default environment for current session or globally
function! mirror#SetDefaultEnv(env, global)
  let env = s:ChooseEnv(a:env)
  if !empty(env)
    let g:mirror#local_default_environments[b:project_with_mirror] = env
    if a:global
      let g:mirror#global_default_environments[b:project_with_mirror] = env
      call s:UpdateCache()
    endif
    let remote_path = get(s:CurrentMirrors(), env)
    echo b:project_with_mirror . ':' env '(' . remote_path . ')'
  endif
endfunction

" Return dictionary from current project config
function! s:CurrentMirrors()
  return get(g:mirror#config, b:project_with_mirror, {})
endfunction

" Check selected environment for existence and return it
function! s:ChooseEnv(env)
  let default_env = s:FindDefaultEnv()
  if empty(s:CurrentMirrors())
    echo 'Project' '"' . b:project_with_mirror . '"'
          \ 'doesn''t have any environments'
          \ '(' . g:mirror#config_path . ')'
  elseif empty(a:env) && empty(default_env)
    echo 'Can''t find default environment for'
          \ '"' . b:project_with_mirror . '"...'
  " env is not given - using default env for current project
  elseif empty(a:env) && !empty(default_env)
    return default_env
  elseif !empty(a:env)
    if has_key(s:CurrentMirrors(), a:env)
      return a:env
    else
      echo 'Environment with name' '"' . a:env . '"'
            \ 'not found in project' '"' . b:project_with_mirror . '"'
            \ '(' . g:mirror#config_path . ')'
    endif
  endif
endfunction

" Find default environment for current project
function! s:FindDefaultEnv()
  let default = ''
  if !empty(s:CurrentMirrors())
    " look for local defaults environments
    let default = get(g:mirror#local_default_environments, b:project_with_mirror, '')
    if empty(default)
      " look for global defaults environments
      let default = get(g:mirror#global_default_environments, b:project_with_mirror, '')
    endif
    if empty(default) && len(keys(s:CurrentMirrors())) ==# 1
      " if project contain only 1 environment - use it as default
      let default = keys(s:CurrentMirrors())[0]
    endif
  endif
  return default
endfunction

" Do remote action of given type
function! mirror#Do(env, type, command)
  let env = s:ChooseEnv(a:env)
  if !empty(env)
    if a:type ==# 'file'
      call s:OpenFile(env, a:command)
    elseif a:type ==# 'diff'
      call s:OpenDiff(env, a:command)
    elseif a:type ==# 'project_dir'
      call s:OpenProjectDir(env, a:command)
    elseif a:type ==# 'parent_dir'
      call s:OpenParentDir(env, a:command)
    elseif a:type ==# 'root_dir'
      call s:OpenRootDir(env, a:command)
    elseif a:type ==# 'push'
      call s:PushFile(env)
    elseif a:type ==# 'pull'
      call s:PullFile(env)
    elseif a:type ==# 'ssh'
      call s:SSHConnection(env)
    elseif a:type ==# 'info'
      call s:GetFileInfo(env)
    endif
  endif
endfunction

" Return list of available environments for current projects
function! s:EnvCompletion(arg_lead, ...)
  if empty(a:arg_lead)
    return keys(s:CurrentMirrors())
  else
    return filter(keys(s:CurrentMirrors()), 'a:arg_lead == v:val[: len(a:arg_lead) - 1]')
  endif
endfunction

" Add Mirror* commands for current buffer
function! mirror#InitForBuffer(current_project)
  let b:project_with_mirror = a:current_project
  command! -buffer -complete=customlist,s:EnvCompletion -nargs=? MirrorEdit
        \ call mirror#Do(<q-args>, 'file', 'edit')
  command! -buffer -complete=customlist,s:EnvCompletion -nargs=? MirrorVEdit
        \ call mirror#Do(<q-args>, 'file', 'vsplit')
  command! -buffer -complete=customlist,s:EnvCompletion -nargs=? MirrorSEdit
        \ call mirror#Do(<q-args>, 'file', 'split')

  command! -buffer -complete=customlist,s:EnvCompletion -nargs=? MirrorOpen
        \ call mirror#Do(<q-args>, 'project_dir', g:mirror#open_with)
  command! -buffer -complete=customlist,s:EnvCompletion -nargs=? MirrorRoot
        \ call mirror#Do(<q-args>, 'root_dir', g:mirror#open_with)
  command! -buffer -complete=customlist,s:EnvCompletion -nargs=? MirrorParentDir
        \ call mirror#Do(<q-args>, 'parent_dir', g:mirror#open_with)

  command! -buffer -complete=customlist,s:EnvCompletion -nargs=? MirrorDiff
        \ call mirror#Do(<q-args>, 'diff', g:mirror#diff_layout)
  command! -buffer -complete=customlist,s:EnvCompletion -nargs=? MirrorVDiff
        \ call mirror#Do(<q-args>, 'diff', 'vsplit')
  command! -buffer -complete=customlist,s:EnvCompletion -nargs=? MirrorSDiff
        \ call mirror#Do(<q-args>, 'diff', 'split')

  command! -buffer -complete=customlist,s:EnvCompletion -nargs=? MirrorPush
        \ call mirror#Do(<q-args>, 'push', '')
  command! -buffer -complete=customlist,s:EnvCompletion -nargs=? MirrorPull
        \ call mirror#Do(<q-args>, 'pull', '')

  command! -buffer -complete=customlist,s:EnvCompletion -nargs=? MirrorSSH
        \ call mirror#Do(<q-args>, 'ssh', '')

  command! -buffer -complete=customlist,s:EnvCompletion -nargs=? MirrorInfo
        \ call mirror#Do(<q-args>, 'info', '')

  command! -buffer -bang -complete=customlist,s:EnvCompletion -nargs=?
        \ MirrorEnvironment call mirror#SetDefaultEnv(<q-args>, <bang>0)

  command! -buffer -bang -nargs=? -complete=dir MirrorDeploy
        \ call mirror#Deploy(<q-args>, <bang>0)
endfunction

" Overwrite remote file with currently opened file
function! s:Deploy(src, env, global)
  if empty(a:src)
    let deploy_path = expand('%')
  else
    let deploy_path = a:src
  endif
  echo deploy_path

  let [port, local_file, remote_file, local_dir, remote_dir] = s:PrepareToDeploy(a:env, deploy_path)


  let command = s:RsyncCommand(port, local_file, remote_file, remote_dir, 1)
  "let command = s:ScpCommand(port, local_file, remote_file)
  let message = 'Deploy to ' . remote_file
  echo command
  return
  call s:ExecuteCommand('MirrorDeploy', command, message)

  return
  "let command = s:ScpCommand(port, local_file, remote_file)
  let command = s:RsyncCommand(port, local_file, remote_file, remote_dir, 1)
  let message = 'Pushed to ' . remote_file
  call s:ExecuteCommand('MirrorPush', command, message)
endfunction

" Find port, local_file and remote_file for current environment
function! s:PrepareToDeploy(env, deploy_path)
  let [local_path, remote_path] = s:FindPaths(a:env)
  let local_path = a:deploy_path .'/'
  let [host, port, path] = s:ParseRemotePath(remote_path . local_path)
  let remote_file = printf('%s:%s', host, path)
  "let local_file = expand('%:p')
  let local_file = getcwd() . '/' . local_path
  let local_dir = fnamemodify(local_file,':h')
  let remote_dir = fnamemodify(path,':h')
  return [port, local_file, remote_file, local_dir, remote_dir]
endfunction



function! mirror#Deploy(dir, global)
  let env = s:ChooseEnv('')
  if !empty(env)
    call s:Deploy(a:dir, env, a:global)
  endif
endfunction

function! mirror#Download(is_parent)
  let cwd = getcwd()
  let configs = mirror#ReadConfig()
  if a:is_parent == 1
    let remote_path = expand('%:h')
  else
    let remote_path = expand('%')
  endif
  let sync_path=''
  
  let projects = reverse(sort(keys(g:mirror#config)))
  for project in projects
    for remote in keys(configs[project])
      if match(remote_path, configs[project][remote]) != -1
        let remote_base_path = configs[project][remote]
        let sync_path = split(remote_path, remote_base_path)[1]
        break
      endif
    endfor
  endfor

  if strlen(sync_path) > 0
    let [host, port, path] = s:ParseRemotePath(remote_path)
    let remote_file = printf('%s:%s', host, path)
    let local_file = cwd.sync_path
    let local_dir = fnamemodify(local_file,':h')
    let command = s:RsyncCommand(port, remote_file, local_file, local_dir, 0) " 0 for local
    let message = 'Download to ' . local_file
    call s:ExecuteCommand('MirrorDownload', command, message)
  endif
endfunction

nmap <silent> <Plug>(mirror-remote-download) :<C-u>call mirror#Download(0)<CR>
nmap <silent> <Plug>(mirror-remote-download-parent) :<C-u>call mirror#Download(1)<CR> 
function! mirror#EnvironmentName()
  if exists('b:project_with_mirror')
    return s:FindDefaultEnv()
  endif
  return ''
endfunction
let g:mirror_environment_name=1

" Build rsync command from args
function! s:RsyncCommand(port, src_path, dest_path, dir_path, is_remote)
  "let port = empty(a:port) ? '' : '-P ' . a:port
  let port = empty(a:port) ? '' : '-e "ssh -p '.a:port.'"'
  if a:is_remote == 1
    return printf('rsync -acvz %s --rsync-path="mkdir -p %s && rsync" %s %s', port, a:dir_path, a:src_path, a:dest_path)
  else
    return printf('mkdir -p %s && rsync -acvz %s %s %s', a:dir_path, port, a:src_path, a:dest_path)
  endif
endfunction

" Find port, local_file and remote_file for current environment
function! s:PrepareToRsync(env)
  let [local_path, remote_path] = s:FindPaths(a:env)
  let [host, port, path] = s:ParseRemotePath(remote_path . local_path)
  let remote_file = printf('%s:%s', host, path)
  let local_file = expand('%:p')
  let local_dir = fnamemodify(local_file,':h')
  let remote_dir = fnamemodify(path,':h')
  return [port, local_file, remote_file, local_dir, remote_dir]
endfunction

nmap <C-k>m <Plug>(mirror-remote-download)
nmap <C-k>M <Plug>(mirror-remote-download-parent)

function! mirror#ProjectDiscovery()
  let file_path = expand('%:p')
  " sorting projects path by its lengths in desc order
  " it helps to avoid discovery of wrong projects in following situation:
  " current working directory: /home/user/work/project
  " configuration include two projects:
  " /home/user/work         <= without sorting, this project will be used
  " /home/user/work/project
  let projects = reverse(sort(keys(g:mirror#config)))
  for project in projects
    if match(file_path, project) != -1
      call mirror#InitForBuffer(project)
      return 1
    endif
  endfor
endfunction

" vim: foldmethod=marker
