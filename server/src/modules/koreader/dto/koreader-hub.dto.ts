import { Type } from 'class-transformer';
import { IsInt, IsOptional, IsString, IsUrl, Matches, Max, MaxLength, Min } from 'class-validator';
import { KoreaderCreateRequestDto } from './koreader-requests.dto';

export class KoreaderHubPageDto {
  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(1)
  @Max(1000)
  page = 1;
}

export class KoreaderCollectionQueryDto extends KoreaderHubPageDto {
  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(1)
  bookId?: number;
}

export class KoreaderCollectionBookDto {
  @IsInt()
  @Min(1)
  bookId!: number;
}

export class KoreaderWishlistBookDto extends KoreaderCreateRequestDto {
  @IsOptional()
  @IsString()
  @MaxLength(2048)
  @IsUrl({ protocols: ['https'], require_protocol: true })
  coverUrl?: string;
}

export class KoreaderWishlistKeyDto {
  @IsString()
  @Matches(/^[a-f0-9]{32}$/)
  key!: string;
}
