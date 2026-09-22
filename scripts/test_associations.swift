import Foundation
@main struct AssociationPolicyTests {
 static func main() {
  var count=0
  func check(_ title:String,_ result:Bool) {count+=1;if !result {fputs("FAIL: \(title)\n",stderr);exit(1)}}
  for ext in ["pot","vhd","p","html","htm","shtml","xhtml","svg","ts","mts","m2ts","ps","plist","tpl","pxd","url","msg","frm","idx","as","ig","pdf","doc","rtf"] {
   check("Protected \(ext)",!AssociationPolicy.eligible(extensions:[ext],isSource:true,current:"com.apple.TextEdit"))
  }
  for ext in AssociationPolicy.sourceExtensions {
   check("Catalog format available: \(ext)",AssociationPolicy.eligible(extensions:[ext],isSource:true,current:"com.apple.TextEdit"))
  }
  for ext in ["txt","json","toml","yaml","yml","jsonc","json5","rs","go","md","cpp","hpp","tsx","css","xml","ini","sql"] {
   check("Essential extension included: \(ext)",AssociationPolicy.sourceExtensions.contains(ext))
  }
  check("Swift in TextEdit",AssociationPolicy.eligible(extensions:["swift"],isSource:true,current:"com.apple.TextEdit"))
  check("Python in VSCode",AssociationPolicy.eligible(extensions:["py"],isSource:true,current:"com.microsoft.VSCode"))
  check("Windsurf is a source editor",AssociationPolicy.eligible(extensions:["swift"],isSource:true,current:"com.exafunction.windsurf"))
  check("Unknown handler stays protected",!AssociationPolicy.eligible(extensions:["py"],isSource:true,current:"example.specialist"))
  check("Browser protected even for source",!AssociationPolicy.eligible(extensions:["js"],isSource:true,current:"com.brave.Browser"))
  check("Media protected",!AssociationPolicy.eligible(extensions:["swift"],isSource:true,current:"org.videolan.vlc"))
  check("No handler",AssociationPolicy.eligible(extensions:["swift"],isSource:true,current:nil))
  check("Non-source rejected",!AssociationPolicy.eligible(extensions:["swift"],isSource:false,current:nil))
  check("Shared ambiguous alias rejected",!AssociationPolicy.eligible(extensions:["swift","ts"],isSource:true,current:nil))
  check("Empty aliases rejected",!AssociationPolicy.eligible(extensions:[],isSource:true,current:nil))
  for aliases in [["md"],["hpp","hh","hp","hxx","h++","ipp"],["js","mjs","jscript","javascript"],["java","jav"],["rb","rbw"]] {
   check("Recognized safe alias group",AssociationPolicy.eligible(extensions:aliases,isSource:true,current:"com.exafunction.windsurf"))
  }
  check("C++ shared group recognized",AssociationPolicy.eligible(extensions:["cpp","cp","cc"],isSource:true,current:nil))
  print("\(count) association safety checks passed")
 }
}
