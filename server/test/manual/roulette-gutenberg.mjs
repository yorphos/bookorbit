// Temporary live-test adapter. Install for the test, then remove it and its source.
// Only the verified public-domain English text of Dracula is exposed.
const url='https://www.gutenberg.org/ebooks/345.epub.noimages';
export default {
 apiVersion:1,version:'1.0.0',type:'roulette-pd-test',label:'Roulette public-domain verification',requiresCredential:false,usesCategories:false,seedsBack:false,mediaKinds:['ebook'],
 search:async query=>query.title.toLowerCase()==='dracula' && /stoker/i.test(query.author||'') ? [{guid:'gutenberg-345-en',title:'Dracula - Bram Stoker - English EPUB (Project Gutenberg)',bookTitle:'Dracula',author:'Bram Stoker',format:'epub',language:'en',downloadUrl:url,infoUrl:'https://www.gutenberg.org/ebooks/345',sizeBytes:null,seeders:null,leechers:null}]:[],
 test:async()=>({success:true}),
 resolveFile:async release=>{if(release.guid!=='gutenberg-345-en')throw new Error('Unknown public-domain fixture');return {url,fileName:'Dracula - Bram Stoker - Gutenberg.epub',format:'epub',sizeBytes:null};},
};
