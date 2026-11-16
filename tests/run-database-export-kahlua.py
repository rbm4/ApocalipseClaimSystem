"""Run production Lua in the installed game's Kahlua with a database double.

Requires the local patch repository's existing API fixture support and game JAR.
No server/database requests or deployments are performed.
"""
import argparse
import json
from pathlib import Path
import sys

sys.dont_write_bytecode = True
parser = argparse.ArgumentParser()
parser.add_argument('--patch-tools', type=Path, default=Path('Z:/git/Github/apocalipsebr-zomboid-patches/tools'))
parser.add_argument('--pack-server', type=Path, default=Path('C:/Users/ricar/Zomboid/Workshop/apocbr/Contents/mods/ApocalisebrPack/42.14/media/lua/server'))
args = parser.parse_args()
sys.path.insert(0, str(args.patch_tools))
import test_api_bridge as fixture

fixture.STUBS['zombie/Lua/LuaManager.java'] = fixture.STUBS['zombie/Lua/LuaManager.java'].replace(
    'final Platform platform', 'final J2SEPlatform platform').replace(
    ' static {', ' public static StackTraceElement[] insertAnyLuaTraceElements(StackTraceElement[] t){return t;}\n public static StackTraceElement[] getLuaStackStrace(se.krka.kahlua.vm.Coroutine c){return new StackTraceElement[0];}\n static {')
fixture.STUBS['zombie/debug/DebugLog.java'] = '''package zombie.debug;
public class DebugLog { public static final DebugLog instance=new DebugLog();
 public static DebugLog getInstance(){return instance;} public boolean isLogTraceFileLocationEnabled(){return false;}
 public static boolean isEnabled(DebugType type){return false;}
 public static void log(String value){System.out.println(value);} }'''
fixture.STUBS['zombie/debug/DebugType.java'] = '''package zombie.debug;
public enum DebugType { Lua, General, Network, Script;
 public DebugLogStream getLogStream(){return new DebugLogStream();}
 public void error(Object value){System.err.println(value);} }'''
fixture.STUBS['zombie/debug/DebugLogStream.java'] = '''package zombie.debug;
public class DebugLogStream extends java.io.PrintStream {public DebugLogStream(){super(System.out);}
 public static String generateCallerPrefix(){return "fixture";}
 public void printException(Throwable error,String a,String b,LogSeverity severity){error.printStackTrace(System.out);}}'''

root = Path(__file__).resolve().parents[1]
server = root / 'Contents/mods/ApocalipseClaimSystem/42.19/media/lua'
sources = {'server/' + path.stem: path for path in (server / 'server').glob('VehicleClaim_Database*.lua')}
sources['server/VehicleClaim_ServerDatabase'] = server / 'server/VehicleClaim_ServerDatabase.lua'
for name in ('VehicleClaim_Shared', 'VehicleClaim_Config'):
    sources['shared/' + name] = server / 'shared' / (name + '.lua')
sources['ApocBR/Entities'] = args.pack_server / 'ApocBR/Entities.lua'
cases = '\n'.join('case ' + json.dumps(name) + ': source=' + json.dumps(path.read_text(encoding='utf-8')) + '; break;'
                  for name, path in sources.items())
test = json.dumps((root / 'tests/database-export.lua').read_text(encoding='utf-8'))
fixture.HARNESS = r'''
package zombie.apocbr.api;
import zombie.Lua.LuaManager;
import se.krka.kahlua.vm.*;
import se.krka.kahlua.stdlib.*;
import se.krka.kahlua.luaj.compiler.LuaCompiler;
public class ApiBridgeTest {
 static Object load(String source)throws Exception {
  LuaClosure closure=LuaCompiler.loadstring(source,"vehicle-export-fixture",LuaManager.env);
  Object[] result=LuaManager.caller.pcall(LuaManager.thread,closure,new Object[]{});
  if(!Boolean.TRUE.equals(result[0]))throw new AssertionError(java.util.Arrays.toString(result));
  return result.length>1?result[1]:null;
 }
 public static void main(String[] args)throws Exception {
  BaseLib.register(LuaManager.env);StringLib.register(LuaManager.platform,LuaManager.env);
  TableLib.register(LuaManager.platform,LuaManager.env);CoroutineLib.register(LuaManager.platform,LuaManager.env);
  se.krka.kahlua.j2se.MathLib.register(LuaManager.platform,LuaManager.env);
  LuaManager.env.rawset("print",(JavaFunction)(frame,count)->{if(count>0)System.out.println(frame.get(0));return 0;});
  load(java.nio.file.Files.readString(java.nio.file.Path.of("Z:/SteamLibrary/steamapps/common/ProjectZomboid/stdlib.lua")));
  load("package={loaded={}};");
  LuaManager.env.rawset("require",(JavaFunction)(frame,count)->{
   try {
    String name=(String)frame.get(0);
    KahluaTable loaded=(KahluaTable)((KahluaTable)LuaManager.env.rawget("package")).rawget("loaded");
    Object value=loaded.rawget(name);
    if(value==null){String source;switch(name){
''' + cases + r'''
     default: throw new IllegalArgumentException(name);
    } value=load(source);loaded.rawset(name,value==null?Boolean.TRUE:value);}
    frame.push(value);return 1;
   }catch(Exception e){throw new RuntimeException(e);}
  });
  load(''' + test + r''');
 }
}
'''
fixture.main()
