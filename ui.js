/* Навигация и отдельное окно авторизации. Настройки аккаунта не изменяются. */
(function(){
'use strict';
var body=document.body,drawer=document.getElementById('sidebar'),open=document.getElementById('openMenu'),close=document.getElementById('closeMenu'),backdrop=document.getElementById('menuBackdrop'),main=document.querySelector('main'),auth=document.getElementById('authPanel');
if(!drawer||!open)return;
function focusables(root){return Array.from(root.querySelectorAll('button:not(:disabled),a[href],input:not(:disabled),select:not(:disabled),[tabindex="0"]')).filter(function(el){return !el.closest('[hidden]')&&getComputedStyle(el).display!=='none';});}
function setMenu(value,returnFocus){if(body.classList.contains('locked'))value=false;body.classList.toggle('menu-open',value);open.setAttribute('aria-expanded',String(value));drawer.setAttribute('aria-hidden',String(!value));drawer.inert=!value;backdrop.hidden=!value;main.inert=value;if(value)close.focus();else if(returnFocus&&!body.classList.contains('locked'))open.focus();}
open.onclick=function(){setMenu(true);};close.onclick=function(){setMenu(false,true);};backdrop.onclick=function(){setMenu(false,true);};
drawer.addEventListener('click',function(e){if(e.target.closest('[data-view]'))setMenu(false,true);});
document.addEventListener('keydown',function(e){var locked=body.classList.contains('locked'),expanded=body.classList.contains('menu-open');if(e.key==='Escape'&&expanded){e.preventDefault();setMenu(false,true);return;}if(e.key!=='Tab'||(!locked&&!expanded))return;var els=focusables(locked?auth:drawer);if(!els.length)return;var first=els[0],last=els[els.length-1];if(e.shiftKey&&(document.activeElement===first||!els.includes(document.activeElement))){e.preventDefault();last.focus();}else if(!e.shiftKey&&(document.activeElement===last||!els.includes(document.activeElement))){e.preventDefault();first.focus();}});
var wasLocked=body.classList.contains('locked');
new MutationObserver(function(){var locked=body.classList.contains('locked');if(locked===wasLocked)return;wasLocked=locked;setMenu(false);if(locked){var input=document.getElementById('authEmail');if(input)input.focus();}else open.focus();}).observe(body,{attributes:true,attributeFilter:['class']});
setMenu(false);
})();
