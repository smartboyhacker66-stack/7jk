@echo off
rem Screen-reader friendly. Plain text only. Every line starts with INFO, ASK, OK, WARN or ERROR.
rem Secrets are never written to the log file.
setlocal EnableExtensions
cd /d "%~dp0"

set "REPO_URL=https://github.com/smartboyhacker66-stack/7jk.git"
set "BRANCH=main"
set "LOGFILE=%~dp0push_to_github.log"
set "OPENROUTER_API_KEY="
set "RENDER_API_KEY="

> "%LOGFILE%" echo Log started %DATE% %TIME%
call :log "INFO: Starting. A copy of this output is saved in push_to_github.log, without any secret keys."

call :log "INFO: Step 1 of 7. Checking that git and PowerShell are installed."
where git >nul 2>&1
if errorlevel 1 (
  call :log "ERROR: Git was not found. Install Git for Windows from git-scm.com, then run this file again."
  goto :end
)
where powershell >nul 2>&1
if errorlevel 1 (
  call :log "ERROR: PowerShell was not found. It is needed to hide your typing and to talk to Render."
  goto :end
)
call :log "OK: Git and PowerShell are installed."

call :log "INFO: Step 2 of 7. Preparing the local git repository."
if not exist ".git" (
  git init >nul 2>&1
  if errorlevel 1 (
    call :log "ERROR: git init failed."
    goto :end
  )
  call :log "OK: Created a new git repository."
) else (
  call :log "OK: A git repository already exists here."
)
git checkout -B %BRANCH% >nul 2>&1
if errorlevel 1 git branch -M %BRANCH% >nul 2>&1
call :log "OK: Using branch main."

call :log "INFO: Step 3 of 7. Committing your files."
git add -A >nul 2>&1
git diff --cached --quiet
if errorlevel 1 (
  git -c user.name="OpenRouter MCP Deploy" -c user.email="deploy@example.invalid" commit -q -m "Deploy OpenRouter MCP server"
  if errorlevel 1 (
    call :log "ERROR: git commit failed."
    goto :end
  )
  call :log "OK: Files committed."
) else (
  call :log "OK: No new changes to commit."
)

call :log "INFO: Step 4 of 7. Pushing to GitHub at %REPO_URL%"
git remote get-url origin >nul 2>&1
if errorlevel 1 (
  git remote add origin %REPO_URL%
) else (
  git remote set-url origin %REPO_URL%
)
call :log "INFO: If a GitHub sign-in window opens, complete the sign-in first."
git push -u origin %BRANCH%
if errorlevel 1 (
  call :log "WARN: The push was rejected. The repository probably already has other commits."
  echo ASK: Type YES and press Enter to overwrite the remote branch. Press Enter alone to stop.
  set "CONFIRM="
  set /p "CONFIRM=Your answer: "
  if /i "%CONFIRM%"=="YES" (
    git push -u --force origin %BRANCH%
    if errorlevel 1 (
      call :log "ERROR: The forced push failed. Check your GitHub sign-in and permissions."
      goto :end
    )
  ) else (
    call :log "ERROR: Stopped by you. Nothing was overwritten."
    goto :end
  )
)
call :log "OK: The code is on GitHub."

call :log "INFO: Step 5 of 7. Collecting your keys. Typing is hidden. Nothing appears while you type or paste. Press Enter when done."
call :prompt_secret OPENROUTER_API_KEY "Paste your OpenRouter API key, then press Enter."
if not defined OPENROUTER_API_KEY (
  call :log "ERROR: No OpenRouter API key was entered."
  goto :end
)
call :log "OK: OpenRouter API key received. It will be set as a secret environment variable on the server."
call :prompt_secret RENDER_API_KEY "Paste your Render API key, then press Enter. Create one in Render under Account Settings, then API Keys."
if not defined RENDER_API_KEY (
  call :log "WARN: No Render API key entered, so the service cannot be created automatically."
  call :log "INFO: Open this address in your browser to deploy with the Blueprint instead:"
  echo https://render.com/deploy?repo=https://github.com/smartboyhacker66-stack/7jk
  call :log "INFO: Render will ask you for OPENROUTER_API_KEY there. MCP_AUTH_TOKEN is generated for you."
  goto :end
)
call :log "OK: Render API key received."

call :log "INFO: Step 6 of 7. Creating the Render service and setting environment variables."
call :log "INFO: This also waits for the first deploy, which usually takes two to five minutes. Progress is reported every 15 seconds."
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0deploy_render.ps1" -RepoUrl "%REPO_URL%" -Branch "%BRANCH%"
if errorlevel 1 (
  call :log "ERROR: The Render step failed. Read the lines above for the reason."
  goto :end
)

call :log "INFO: Step 7 of 7. Done. Your final MCP URL and access token are printed above."

:end
set "OPENROUTER_API_KEY="
set "RENDER_API_KEY="
echo.
echo INFO: Finished. Press any key to close this window.
pause
endlocal
exit /b

:log
echo %~1
>> "%LOGFILE%" echo %~1
exit /b 0

:prompt_secret
rem %1 is the variable name to fill. %2 is the question.
echo ASK: %~2
for /f "usebackq delims=" %%A in (`powershell -NoProfile -Command "$s = Read-Host -AsSecureString; [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s))"`) do set "%~1=%%A"
exit /b 0
