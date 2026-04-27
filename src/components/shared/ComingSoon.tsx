interface Props { title: string; icon: string; }

export default function ComingSoon({ title, icon }: Props) {
  return (
    <div style={{ display:'flex', flexDirection:'column', alignItems:'center', justifyContent:'center', minHeight:320, color:'#94a3b8', gap:16 }}>
      <i className={`fa-solid ${icon}`} style={{ fontSize:48, color:'#cbd5e1' }} />
      <h2 style={{ fontSize:20, fontWeight:700, color:'#1a2f4e', margin:0 }}>{title}</h2>
      <p style={{ margin:0, fontSize:13 }}>This section is being migrated to React. Coming soon.</p>
    </div>
  );
}
