/// Ordenação "humana": trechos numéricos comparados como inteiros (#10 antes de #100).
int naturalCompare(String a, String b) {
  final la = a.toLowerCase();
  final lb = b.toLowerCase();
  var i = 0;
  var j = 0;
  while (i < la.length && j < lb.length) {
    final ca = la.codeUnitAt(i);
    final cb = lb.codeUnitAt(j);
    final da = ca >= 48 && ca <= 57;
    final db = cb >= 48 && cb <= 57;
    if (da && db) {
      var ia = i;
      while (ia < la.length) {
        final u = la.codeUnitAt(ia);
        if (u < 48 || u > 57) break;
        ia++;
      }
      var jb = j;
      while (jb < lb.length) {
        final u = lb.codeUnitAt(jb);
        if (u < 48 || u > 57) break;
        jb++;
      }
      final na = int.parse(la.substring(i, ia));
      final nb = int.parse(lb.substring(j, jb));
      if (na != nb) return na.compareTo(nb);
      final w = (ia - i).compareTo(jb - j);
      if (w != 0) return w;
      i = ia;
      j = jb;
    } else {
      if (ca != cb) return ca.compareTo(cb);
      i++;
      j++;
    }
  }
  return la.length.compareTo(lb.length);
}
