// beegent: white canvas, charcoal text, honey actions and cream disabled controls.
export class Palette {
  static readonly background: string = '#FFFFFF';
  static readonly surface: string = '#FFFFFF';
  static readonly ink: string = '#24231F';
  static readonly muted: string = '#817867';
  static readonly disabled: string = '#F4E9D2';
  static action(enabled: boolean): string { return enabled ? Palette.honey : Palette.disabled; }
  static readonly honey: string = '#E6AE50';
  static readonly soft: string = '#F7F7F5';
  static readonly line: string = '#E8E6E1';
}
