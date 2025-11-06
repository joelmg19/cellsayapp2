const Set<String> kCartelLabelSet = {
  'anuncios informativos',
  'anuncios publicitarios',
  'carteles de comida',
  'letrero direccion',
  'letrero tienda',
  'publicidad de comida',
};

bool isCartelLabel(String? label) {
  if (label == null) return false;
  return kCartelLabelSet.contains(label.trim().toLowerCase());
}
